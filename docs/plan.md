# Plan: Larkspur Logistics Azure Platform

> Larkspur Logistics is a **fictional** company. This repository is a hands-on lab: a small, single-subscription
> landing zone run with production practices. It is not Microsoft's enterprise-scale landing zone architecture and
> it is not a production system.

Plan approved: 2026-11-12. Region: `eastus`.

## Scenario

Larkspur Logistics is a regional freight carrier with an HQ and several depots. Customers want to check shipment
status online. The company needs a shipment-tracking API that is:

- **Private on the data side**: the database and secrets are reachable only over the private network.
- **Passwordless**: the app authenticates with a managed identity, so no connection-string passwords exist.
- **Deployed through a pipeline**: every change gets lint and what-if on a pull request, plus an approval gate before deploy.
- **Observable**: logs, alerts and a workbook show health and cost.
- **Recoverable**: restores are tested and RTO/RPO are measured, not assumed.
- **Governed**: policy, tags, locks, budgets and least-privilege access.

## Architecture (target)

```
Internet ──HTTPS──▶ Container App "tracking-api" (Consumption profile, scales to 0)
                     │  user-assigned managed identity
  vnet-lark 10.60.0.0/16
   ├─ snet-aca  10.60.0.0/27    delegated Microsoft.App/environments
   ├─ snet-pe   10.60.1.0/27    ──▶ PE ──▶ Azure SQL Database (free tier, Entra-only auth)
   │                             ──▶ PE ──▶ Key Vault (RBAC, public network access off)
   └─ GatewaySubnet 10.60.255.0/27  reserved and documented, NOT deployed
  Private DNS zones: privatelink.database.windows.net, privatelink.vaultcore.azure.net
  Log Analytics (daily cap) ◀── diagnostic settings ── SQL, Key Vault, Container Apps
  GitHub Actions ──OIDC──▶ lint + what-if on PR ──▶ approval ──▶ deploy ──▶ verify
```

### Address plan

`10.60.0.0/16` avoids every range used by earlier labs (10.0–10.2 P1, 10.40–10.41 P3, 10.90 earlier labs).

| Subnet | Prefix | Purpose |
|---|---|---|
| snet-aca | 10.60.0.0/27 | Container Apps environment (minimum `/27` for workload-profiles environments) |
| snet-pe | 10.60.1.0/27 | Private endpoints |
| GatewaySubnet | 10.60.255.0/27 | Reserved for depot VPN (conceptual; proven in azure-hub-spoke-network Lab 9) |

### Resource groups

| Group | Lifetime | Contents |
|---|---|---|
| rg-lark-data | Persistent (near $0 idle) | SQL server + free database, Key Vault, Log Analytics, alert rules, action group, private DNS zones |
| rg-lark-app | Torn down every session; redeployed by the pipeline | VNet, NSGs, private endpoints, Container Apps environment + app, managed identity |

Private DNS zones moved to `rg-lark-data` after M0 pricing: a zone is priced per month ($0.63 in `eastus` on
2026-11-12) and it isn't confirmed whether a zone that exists for part of a month is prorated. Keeping two
persistent zones caps that at ~$1.26/month instead of risking a charge per session. It also matches real landing
zones, where DNS zones are shared platform resources and workload VNets link to them. The teardown script deletes
the VNet links before deleting `rg-lark-app`.

## Reused patterns

| Source repo | Reused |
|---|---|
| azure-hub-spoke-network | VNet/subnet/NSG module patterns; Lab 9 VPN evidence for the conceptual depot link |
| azure-bicep-cicd-pipeline | OIDC identities, `Initialize-PipelineIdentity.ps1`, `deploy-env` composite action, lint-as-error `bicepconfig.json`, pinned Bicep |
| azure-access-troubleshooting-lab | Key Vault RBAC, managed identity, access-denied diagnosis |
| azure-storage-private-endpoints-lab | Private endpoint + private DNS zone pattern and DNS verification |
| azure-monitoring-incident-response | Log Analytics daily cap, action group, alerts, workbook |
| azure-backup-dr-lab | RTO/RPO measurement and restore evidence format |

## Milestones

Every milestone includes portal work as well as Bicep/CLI, and saves sanitized evidence under `docs/evidence/`.

| # | Milestone | Acceptance criteria |
|---|---|---|
| M0 | Prerequisites | Repo created; providers registered; existing policy assignments/exemptions reviewed; prices captured; budget deployed and what-if NoChange |
| M1 | Governance | Resource groups created from Bicep with tags; policy assignments at resource-group scope (require `costCenter` tag, allowed locations, SQL public network access denied in rg-lark-data); Entra groups `lark-ops` / `lark-dev` created in the portal with least-privilege RBAC; untagged and wrong-region deployments denied, compliant one allowed; second what-if NoChange |
| M2 | Network | VNet, subnets, NSGs and private DNS zones deployed from Bicep; second what-if run shows NoChange |
| M3 | Data and secrets | SQL free database with Entra-only auth + PE; Key Vault + PE; `CanNotDelete` locks on the SQL server and Key Vault; `nslookup` from inside the VNet resolves to private IPs; public access is refused; private endpoint cost read from Cost Analysis |
| M4 | App | Image built by GitHub Actions and pushed to GHCR; Container App reads shipments from SQL with its managed identity; Cost Analysis shows no Container Apps management-hour charge |
| M5 | CI/CD | PR runs lint + what-if; merge to main waits for approval, deploys, verifies, and passes an idempotency check |
| M6 | Observability | Diagnostic settings; alerts on HTTP 5xx, SQL "Free amount remaining" < 10,000 vCore-seconds, and budget; a workbook |
| M7 | Recovery | SQL point-in-time restore with measured RTO/RPO; Key Vault secret soft-delete recovery; Container App revision rollback |
| M8 | Game day | 4–5 scripted incidents, each with a prediction recorded first, then symptoms, evidence, root cause, fix, verification and an RCA |
| M9 | Deliverables | README, architecture diagram, runbook, cost report, teardown script, interview guide |

### Game-day incidents (M8)

1. Private DNS zone VNet link removed: app can't reach SQL.
2. Managed identity's Key Vault role assignment removed: 403 from Key Vault.
3. Bad revision deployed: roll back by shifting traffic to the previous revision.
4. Policy denies a non-compliant deployment.
5. SQL database won't auto-pause and starts consuming its free vCore-seconds.

## Cost

| Item | Expected cost |
|---|---|
| Azure SQL Database free tier | $0: 100,000 vCore-seconds, 32 GB data and 32 GB backup per database per month; auto-pauses when idle |
| Container Apps (Consumption) | $0 within the monthly free grant (180,000 vCPU-seconds, 360,000 GiB-seconds, 2M requests per subscription) |
| Private endpoints (2) | ~$0.01/hr each; deleted every session |
| Private DNS zones (2, persistent) | ~$1.26/month |
| Key Vault, alert rules | Pennies per month |
| Log Analytics | Within the free ingestion allowance; daily cap set |
| **Per session estimate** | **< $0.25**; idle month ~$1.50 |
| M7 one-off | Point-in-time restore creates a paid serverless database (restores can't target the free tier): ~$0.25–$0.50, deleted right after verification |

Known risk: Container Apps bills an environment management hour (~$0.10/hr) for environment private endpoints and
some other features. This design does not use an environment private endpoint. M4 confirms no such charge appears
in Cost Analysis.

## Security

- No secrets in the repo. Personal values live in gitignored `*.local.bicepparam` files.
- SQL uses Microsoft Entra-only authentication; no SQL logins.
- Key Vault uses Azure RBAC with public network access disabled.
- The pipeline authenticates with OIDC (no client secrets), using separate plan and deploy identities.
- Evidence is sanitized: GUIDs, 32-hex values, emails and public IPs are masked before commit.

## Conceptual only (documented, not deployed)

| Component | Why not deployed | Production would add |
|---|---|---|
| Depot site-to-site VPN | VPN gateway ~$0.19/hr and 30+ min deploy; already proven in hub-spoke Lab 9 | VPN gateway in GatewaySubnet, local network gateways per depot |
| Azure Firewall | ~$0.40/hr+ | Centralized egress filtering with UDRs |
| Front Door / WAF | Base fee per month | Global entry point and web application firewall |
| Multi-region | Doubles cost | Paired-region failover, geo-replication |

## Design changes after planning

| When | Change | Why |
|---|---|---|
| M0 | Private DNS zones moved to rg-lark-data | Zone priced per month; persistent zones cap cost at ~$1.26/month |
| M1 | `CanNotDelete` lock moved from the whole rg-lark-data group to the SQL server and Key Vault (M3) | A group lock also locks child resources, so it would block deleting the private DNS zone VNet links during per-session teardown |
| M1 | Policies assigned at resource-group scope | The subscription hosts other lab projects; a subscription-wide tag requirement would deny their redeployments |

## Teardown

- End of every session: delete the private DNS zone VNet links, then delete `rg-lark-app` (the pipeline recreates both).
- `rg-lark-data` stays: the SQL free database auto-pauses and the rest costs pennies.
- End of project: remove the lock, delete both groups, delete the budget, remove the OIDC app registrations.
