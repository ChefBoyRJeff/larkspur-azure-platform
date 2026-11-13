# Plan: Larkspur Logistics Azure Platform

> Larkspur Logistics is a **fictional** company. This is a personal portfolio project, designed, built and operated
> end to end on my own Azure subscription: a small, single-subscription landing zone run with production practices.
> It is not Microsoft's enterprise-scale landing zone architecture and it is not a production system serving real
> customers.

Plan approved: 11-12-2026. Region: `eastus` (the SQL server is in `centralus`; see INC-001).

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
| rg-lark-app | Group persistent (it carries the M1 policy and RBAC assignments); contents torn down every session and redeployed | VNet, NSGs, private endpoints, Container Apps environment + app, managed identity |

Private DNS zones moved to `rg-lark-data` after M0 pricing: a zone is priced per month ($0.63 in `eastus` on
11-12-2026) and it isn't confirmed whether a zone that exists for part of a month is prorated. Keeping two
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
| M2 | Network | Private DNS zones (rg-lark-data) and vnet-lark with snet-aca, snet-pe and NSGs (rg-lark-app) deployed from Bicep; zones linked to the VNet; NSG enforcement enabled for private endpoints; second what-if NoChange; teardown script empties rg-lark-app and removes the links |
| M3 | Data and secrets | SQL server (Entra-only auth, admin = `lark-sql-admins` group, public access disabled) with a free-tier database; Key Vault (RBAC, public access disabled, soft delete + purge protection); `CanNotDelete` lock on the database; private endpoints in snet-pe with DNS zone groups writing private A records; from outside the VNet SQL and Key Vault refuse connections; the M1 policy denies re-enabling SQL public access; the lock blocks deleting the database; teardown deletes the private endpoints with the protection in place; second what-if NoChange. Private endpoint cost confirmed in Cost Analysis (cost data lags about a day) |
| M4a | Container Apps environment | Workload-profiles environment (Consumption only) in snet-aca, external; managed group named `rg-lark-app-infra` and covered by the budget; Log Analytics workspace (0.1 GB/day cap) in rg-lark-data; quickstart app answers HTTP 200 from the internet (proves ingress and egress from the private subnet); a job inside the VNet resolves both data-tier names to 10.60.1.x; teardown removes the environment and its managed group |
| M4b | App | Image built by GitHub Actions and published to a public GHCR package; persistent identities `id-lark-tracking-api` (Key Vault Secrets User) and `id-lark-migrator` (Key Vault Secrets Officer, member of `lark-sql-admins`); migration job creates schema, seed data, the app's contained user (SELECT on dbo.Shipments only) and a generated secret; from the internet `/readyz` reports private DNS, SQL and Key Vault healthy and `/shipments/LRK100001` returns data; Cost Analysis shows no Container Apps management-hour charge (checked the next day) |
| M5 | CI/CD | OIDC identities with no secrets: `gh-lark-plan` (custom read + what-if role on both groups) and `gh-lark-deploy` (Contributor on rg-lark-app + custom "Larkspur Data-Tier Integrator" on rg-lark-data + custom "Larkspur Group Reader" on the subscription), trusted only for pull requests and the `production` environment respectively; PRs run lint, type checks, what-if and a guardrail that proves the plan identity can't deploy; `deploy` (manual, approval-gated) deploys a GHCR image pinned to a commit SHA, runs the migration, smoke-tests from the internet and fails on any drift beyond documented what-if noise; `teardown` (approval-gated) ends the session and proves `rg-lark-app` is empty and `rg-lark-app-infra` is gone |
| M6 | Observability | Diagnostic settings; alerts on HTTP 5xx, SQL "Free amount remaining" < 10,000 vCore-seconds, and budget; a workbook |
| M7 | Recovery | SQL point-in-time restore with measured RTO/RPO; Key Vault secret soft-delete recovery; Container App revision rollback |
| M8 | Operations | 4–5 operational incidents, each with symptoms, diagnosis, root cause, fix, verification and an incident report |
| M9 | Deliverables | README, architecture diagram, runbook, cost report, teardown script, interview guide |

### Operational incidents (M8)

Each incident is handled the way an operations team would: alert or report, triage, diagnosis, fix, verification,
then an incident report with root cause and prevention.

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
| Container Apps environment infrastructure (Standard Load Balancer + 2 public IPs) | ~$0.035–0.04/hr while the environment exists (estimate); deleted every session |
| Log Analytics | Free ingestion allowance; 0.1 GB/day cap |
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
| M1 | Policies assigned at resource-group scope | The subscription hosts my other projects; a subscription-wide tag requirement would deny their redeployments |
| M2 | rg-lark-app kept; only its contents are torn down | Deleting the group would delete its M1 policy and RBAC assignments, and recreating those needs rights the pipeline shouldn't have |
| M3 | In-VNet DNS resolution check moved from M3 to M4 | Nothing runs inside the VNet until the Container Apps environment exists; M3 proves the private A records and the public-side refusal instead |
| M3 | SQL admin is a dedicated `lark-sql-admins` group, not `lark-ops` | Ops manages alerts and workbooks without data access (M1); database administration is a separate, smaller group |
| M3 | SQL server in Central US; everything else stays in East US (INC-001) | New SQL servers are provisioning-restricted for this subscription in eastus, eastus2, northcentralus, westus and westus2 (SQL capabilities probe, 11-12-2026); centralus is the closest available region. The private endpoint stays in vnet-lark and connects across regions; only `rg-lark-data` allows `centralus` |
| M3 | SQL server name includes the region in its hash (INC-001) | Resource Manager kept the failed East US server's name reserved for that region |
| M3 | Lock moved from SQL server to database; Key Vault lock removed (INC-002) | A lock also covers the private endpoint connection records Azure deletes with each endpoint, so it blocked teardown. The database lock still protects the data; Key Vault relies on soft delete + purge protection |
| M4a | Log Analytics workspace moved from M6 to M4a | The Container Apps environment needs a log destination, and the in-VNet DNS check reads its output from the logs |
| M4a | Container Apps managed resource group named `rg-lark-app-infra` and added to the budget | A VNet-integrated environment creates a Standard Load Balancer and public IPs billed outside Container Apps; under the default `ME_…` name the budget wouldn't see them |
| M4b | Managed identities live in rg-lark-data, not rg-lark-app | rg-lark-app is rebuilt every session; a rebuilt identity gets a new client ID, which would leave stale database users and role assignments |
| M4b | Container image in public GHCR instead of Azure Container Registry | The image holds no secrets; GHCR is free, Container Registry Basic is ~$0.17/day |
| M5 | Container Apps logs via an Azure Monitor diagnostic setting instead of the environment's Log Analytics key | The key-based setting puts the workspace key value through the template and makes what-if read it. A diagnostic setting keeps the key out of the template and deployment history; the deploy identity still needs `sharedKeys/action` on the workspace for Azure's linked-scope check (INC-003) |
| M5 | The pipeline deploys only the app stack; governance and the data tier stay admin-deployed | They hold policies, locks, role assignments and data. The deploy identity gets only what the app stack touches in rg-lark-data, through a custom role |
| M5 | Deployments are started manually (with approval), not on every push | The app stack is torn down after every session for cost; a session starts by running `deploy` and ends with `teardown` |
| M5 | Diagnostic setting declared exactly as Azure stores it (audit group and AllMetrics disabled, zero retention, no destination type) | Azure fills those in and stores the destination type as null; declaring only what I wanted made every deploy show drift |
| M5 | Deploy identity gets custom "Larkspur Group Reader" (resourceGroups/read) on the subscription (INC-004) | Container Apps creates and deletes rg-lark-app-infra itself, so no role can be granted on it in advance; without read on the subscription, teardown can't prove the billing group is gone. This is the design's only subscription-scope assignment |
| M5 | `deploy` retries once, only for "pending delete operation" (INC-003) | Azure briefly rejects recreating a container app whose identity record from the last teardown is still being cleaned up; every other failure stops the run |

## Teardown

- End of every session: `scripts/Remove-LarkAppResources.ps1` deletes the private DNS zone VNet links, then everything
  inside `rg-lark-app` in dependency order, and verifies the group is empty. The group itself stays, because deleting
  it would also delete its policy and RBAC assignments.
- `rg-lark-data` stays: the SQL free database auto-pauses and the rest costs pennies.
- End of project: remove the lock, delete both groups, delete the budget, remove the OIDC app registrations.
