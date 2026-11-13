# Larkspur Logistics Azure Platform

> **Status:** in progress. M0–M3 delivered; next is M4 (application on Azure Container Apps).
> See [docs/plan.md](docs/plan.md) for the full plan and acceptance criteria.

## Scenario

Larkspur Logistics is a **fictional** regional freight carrier with an HQ and several depots. In this project I
design, build and operate the Azure platform behind its customer shipment-tracking API: private data access,
passwordless identity, pipeline-only deployments, monitoring, tested recovery and policy guardrails.

This is my personal portfolio project, built end to end on my own Azure subscription. It's a small,
single-subscription landing zone that I run with production practices. It is not Microsoft's enterprise-scale
landing zone architecture, and it is not a production system serving real customers.

## Architecture (current state)

```
                          vnet-lark 10.60.0.0/16  (East US, rg-lark-app: rebuilt every session)
                          ├─ snet-aca 10.60.0.0/27   delegated to Container Apps (M4)
                          └─ snet-pe  10.60.1.0/27   NSG: only snet-aca → 1433 / 443
                               ├─ pe-lark-sql 10.60.1.5 ──▶ sql-lark-… (Central US) ─ sqldb-lark-tracking (free tier, locked)
                               └─ pe-lark-kv  10.60.1.4 ──▶ kv-lark-… (East US, purge protection)

  rg-lark-data (persistent): SQL server + database, Key Vault, private DNS zones
    privatelink.database.windows.net   A sql-lark-… → 10.60.1.5   (written by the endpoint's DNS zone group)
    privatelink.vaultcore.azure.net    A kv-lark-…  → 10.60.1.4

  From the internet: SQL refuses connections (error 47073), Key Vault returns ForbiddenByConnection.
```

## Scope

- Governance: Azure Policy, tags, resource locks, budgets, Entra groups with least-privilege RBAC
- Network: VNet, NSGs, private endpoints, private DNS
- Data and secrets: Azure SQL Database (free tier, Entra-only auth), Key Vault (RBAC)
- App: Azure Container Apps with a managed identity
- CI/CD: GitHub Actions with OIDC, what-if on pull requests, approval-gated deploys
- Operations: Log Analytics, alerts, a workbook, tested restores and incident reports

## Repository structure

```
infra/
  budget.bicep                 $5/month budget on both resource groups (subscription scope)
  governance/                  resource groups, policy assignments, group RBAC (subscription scope)
  shared/naming.bicep          globally unique names, shared by both stacks
  data/                        rg-lark-data: private DNS zones, SQL server + database, Key Vault (persistent)
  app/                         rg-lark-app: VNet, NSGs, DNS links, private endpoints (rebuilt each session)
scripts/
  Remove-LarkAppResources.ps1  end-of-session teardown
docs/
  plan.md                      plan, milestones, acceptance criteria, design changes
  incidents/                   incident reports (root cause, remediation, prevention)
  evidence/                    sanitized command output for every milestone
```

Values that identify my tenant (group object IDs, my alert email) live in gitignored `*.local.bicepparam` files,
generated from the committed `*.example.bicepparam` files.

## Progress

| Milestone | Status | Records |
|---|---|---|
| M0 Prerequisites | ✅ Delivered 11-12-2026 | [`docs/evidence/m0-*`](docs/evidence/) |
| M1 Governance | ✅ Delivered 11-12-2026 | [`docs/evidence/m1-*`](docs/evidence/) |
| M2 Network | ✅ Delivered 11-12-2026 | [`docs/evidence/m2-*`](docs/evidence/) |
| M3 Data and secrets | ✅ Delivered 11-12-2026 | [`docs/evidence/m3-*`](docs/evidence/), [INC-001](docs/incidents/INC-001-sql-region-restricted.md), [INC-002](docs/incidents/INC-002-lock-blocks-private-endpoint-teardown.md) |
| M4–M9 | Not started | |

### M0: Prerequisites

- **Providers:** I registered the 8 resource providers the platform needs before deploying anything.
- **Existing policy:** my subscription already has a `deny-costly-resources` assignment (built-in *Not allowed
  resource types*, from my hub-spoke project) that blocks gateways, firewalls, Bastion, NAT, Application Gateway,
  ExpressRoute, DDoS and vWAN hubs. Nothing in this design uses those types, so I didn't need an exemption.
- **Prices (eastus, retail):** I pulled real prices from the Azure Retail Prices API. Container Apps bills $0.10/hr
  for *Environment Management Hour*, *Dedicated Plan Management* and *Environment Private Endpoint*; my design avoids
  all three, and M4 has to prove that in Cost Analysis. SQL serverless General Purpose is $0.52/vCore-hour beyond the
  free tier. Log Analytics ingestion is free for the first 5 GB, then $2.30/GB. A private DNS zone is $0.63/month,
  so I keep the zones in the persistent resource group instead of recreating them every session.
- **Budget:** I deployed a $5/month budget on `rg-lark-data` and `rg-lark-app` before either group existed.
- **What-if false positive:** after deploying the budget, what-if reported `Modify` on its `contactEmails`. What-if
  can't evaluate `@secure()` parameter values, so it shows the expression instead of the value. I compared SHA-256
  hashes of the deployed and local email values: all three notifications matched, so it's noise, not drift. I kept
  `@secure()`, because removing it would write a personal email address into deployment history.

### M1: Governance

**What I built** (`infra/governance/`): both resource groups with standard tags; policy assignments at
resource-group scope (require a `costCenter` tag, allowed locations, and deny Azure SQL public network access in
`rg-lark-data`); and Entra security groups `lark-ops` and `lark-dev`, which I created in the portal, with
least-privilege RBAC.

| Group | rg-lark-data | rg-lark-app | Why |
|---|---|---|---|
| lark-ops | Reader, Monitoring Contributor | Reader | Operate alerts and workbooks without touching data or secrets |
| lark-dev | none | Reader | Changes ship through the pipeline, not the portal |
| lark-sql-admins (M3) | SQL Entra admin | none | Database administration is a separate, smaller group |

**Key decisions**

- I scoped the policies to the two Larkspur resource groups, not the subscription. My subscription also hosts my
  other projects, and a subscription-wide tag rule would deny their redeployments.
- I grant access to groups, never to individual users, so access changes are membership changes.
- I didn't lock the `rg-lark-data` group. A group lock also locks child resources and would have blocked the
  per-session teardown of the private DNS zone links (see M3 for where the protection ended up).

**Verification**

| Check | Expected | Result |
|---|---|---|
| NSG without `costCenter` tag (eastus) | Denied | ✅ `RequestDisallowedByPolicy`: "Every Larkspur resource needs a costCenter tag…" |
| NSG with tag in `westus` | Denied | ✅ `RequestDisallowedByPolicy`: "Larkspur resources must be deployed to: eastus." |
| NSG with tag in `eastus` | Allowed | ✅ Created, then deleted |
| Re-run what-if after deploy | NoChange | ✅ `11 no change` (after the fix below) |

I wrote custom non-compliance messages in Bicep, and they appear directly in the deny error, so whoever hits a
guardrail learns the rule from the error itself.

**Problem I found and fixed: what-if drift on every run.** The first post-deploy what-if reported `Modify` on all
five policy assignments: `- properties.definitionVersion: "1.*.*"`. Azure now versions built-in policy definitions
and stores `1.*.*` (latest 1.x) when an assignment doesn't specify one. My code didn't declare it, so every what-if
proposed removing it. I moved to API `2024-04-01` (the first version with `definitionVersion`) and declared
`definitionVersion: '1.*.*'`; the re-run showed `11 no change`. Pinning the major version also means a breaking 2.x
of a built-in policy can't silently change these guardrails.

### M2: Network

**What I built**

- `infra/data/` → `rg-lark-data`: private DNS zones `privatelink.database.windows.net` and
  `privatelink.vaultcore.azure.net` (persistent, shared platform service).
- `infra/app/` → `rg-lark-app`: `vnet-lark` (10.60.0.0/16) with `snet-aca` (10.60.0.0/27, delegated to
  `Microsoft.App/environments`) and `snet-pe` (10.60.1.0/27), an NSG on each, and VNet links into both zones.
- `scripts/Remove-LarkAppResources.ps1`: my end-of-session teardown.

| NSG | Priority | Rule | Purpose |
|---|---|---|---|
| nsg-lark-aca | 100 | AzureLoadBalancer → 30000-32767 | Health probes to the environment nodes |
| | 110 | snet-aca ↔ snet-aca | Container Apps infrastructure traffic |
| | 120 | Internet → 80, 443, 31080, 31443 | Public tracking API and environment edge proxy |
| | 4000 | Deny VirtualNetwork | Overrides the default `AllowVnetInBound` |
| nsg-lark-pe | 100 | snet-aca → 1433 | App to SQL private endpoint |
| | 110 | snet-aca → 443 | App to Key Vault private endpoint |
| | 4000 | Deny VirtualNetwork | Only the app subnet reaches the private endpoints |

**Key decisions**

- **Two stacks split by lifecycle.** The DNS zones are persistent and shared; the VNet and everything in it are
  rebuilt each session. The VNet links are children of the zones, so they deploy into `rg-lark-data` from the app
  stack.
- **I explicitly enabled NSG enforcement for private endpoints** (`privateEndpointNetworkPolicies:
  NetworkSecurityGroupEnabled`). Without it, Azure ignores NSG rules for traffic to private endpoints, and the
  `nsg-lark-pe` rules would be decoration.
- **Explicit `Deny-VNet-Inbound` at 4000** on both NSGs. Azure's default `AllowVnetInBound` would let anything in
  the VNet, and later anything peered or connected over VPN (depots), reach the data path.
- **Private subnets** (`defaultOutboundAccess: false`): no implicit internet egress. In M4 I have to verify the
  Container Apps environment's own outbound path still pulls images and reaches Entra ID.
- **My teardown empties `rg-lark-app` but keeps the group**, because the group carries the M1 policy and RBAC
  assignments. The script deletes in dependency order (DNS links → app → environment → private endpoints → VNet →
  NSGs → identities), leaves unknown resource types alone and reports them, and verifies the group is empty.

**Verification**

| Check | Result |
|---|---|
| Lint, both stacks | ✅ exit 0 |
| Deploy, both stacks | ✅ `Succeeded`; no policy denials |
| `global` resources vs the allowed-locations policy | ✅ DNS zones and links allowed (the built-in exempts `global`) |
| Zones and links | ✅ 1 link per zone, `Completed`, auto-registration off, `costCenter` tag present |
| Subnets | ✅ delegation, NSGs, `NetworkSecurityGroupEnabled` on `snet-pe`, default outbound off |
| Rebuild from code + what-if | ✅ `5 no change` (after the fix below) |
| Teardown | ✅ links → VNet → NSGs deleted, `rg-lark-app` empty, zones kept, guardrails still assigned |

**Problems I found and fixed**

1. **What-if drift on `vnet-lark`.** The post-deploy what-if reported `- properties.privateEndpointVNetPolicies:
   "Disabled"`. Azure stores this VNet-level property (API 2024-03-01 and later) with a default, and my template
   didn't declare it. I declared `privateEndpointVNetPolicies: 'Disabled'`.
2. **My first fix didn't reach the deployment.** The re-run still showed the drift. When I checked the file that was
   actually used, it was the old version (no `privateEndpointVNetPolicies` line, 6,291 bytes instead of 6,655), so
   the deployment had run against stale code. With the corrected file in place (verified by content and size), a
   full rebuild from code returned `5 no change`. My takeaway: when a fix "doesn't work", verify the artifact that
   was deployed before changing the fix.

### M3: Data and secrets

**What I built**

- `infra/data/modules/sql.bicep`: SQL logical server `sql-lark-…` in **Central US** with Microsoft Entra-only
  authentication (admin = the `lark-sql-admins` group), public network access disabled, TLS 1.2; and the
  `sqldb-lark-tracking` database on the **free tier** (`useFreeLimit`, `AutoPause` at the monthly limit), protected
  by a `CanNotDelete` lock.
- `infra/data/modules/keyvault.bicep`: Key Vault `kv-lark-…` in East US with Azure RBAC authorization, public
  network access disabled, network ACL `Deny` with no trusted-service bypass, soft delete (7 days) and purge
  protection.
- `infra/app/modules/private-endpoints.bicep`: `pe-lark-sql` and `pe-lark-kv` in `snet-pe`, each with a DNS zone
  group that writes its private A record into the shared zone and removes it when the endpoint is deleted.
- `infra/shared/naming.bicep`: deterministic, globally unique names that both stacks import, so the stack that
  creates the SQL server and the stack that points an endpoint at it can never disagree.

**Key decisions**

- **No passwords anywhere.** Entra-only authentication means no SQL logins exist; in M4 the app will connect with
  its managed identity.
- **Private-only data tier.** Public network access is off on both services, and the M1 policy denies anyone who
  tries to turn SQL public access back on.
- **Protection where the data is** ([INC-002](docs/incidents/INC-002-lock-blocks-private-endpoint-teardown.md)). I
  first locked the SQL server and Key Vault, but a lock also covers the private endpoint connection records Azure
  deletes with each endpoint, so it blocked my teardown. I moved the lock to the database and rely on soft delete +
  purge protection for Key Vault.
- **SQL in Central US, everything else in East US** ([INC-001](docs/incidents/INC-001-sql-region-restricted.md)). My
  subscription is restricted from creating new SQL servers in East US and four other US regions. The private
  endpoint stays in vnet-lark and connects across regions, and only `rg-lark-data` allows `centralus`.

**Verification**

| Check | Result |
|---|---|
| SQL server | ✅ `centralus`, public access `Disabled`, Entra-only, admin `lark-sql-admins` (Group), TLS 1.2 |
| Database | ✅ `GP_S_Gen5`, `useFreeLimit: true`, `AutoPause`, online |
| Key Vault | ✅ RBAC, public access `Disabled`, ACL `Deny`/`None`, purge protection, 7-day soft delete |
| Private endpoints | ✅ both `Approved`; SQL endpoint in East US → server in Central US |
| Private DNS | ✅ `sql-lark-…` → 10.60.1.5, `kv-lark-…` → 10.60.1.4 (match the endpoint NICs) |
| SQL login from the internet with a SQL login | ✅ refused: "Azure Active Directory only authentication is enabled" |
| SQL from the internet with a **valid Entra admin token** | ✅ refused: "Deny Public Network Access is set to Yes", error **47073** |
| Key Vault data plane from the internet | ✅ `ForbiddenByConnection` |
| Re-enable SQL public access | ✅ `RequestDisallowedByPolicy` with my custom message; still `Disabled` |
| Delete the database | ✅ `ScopeLocked`; database still present |
| Rebuild from code + what-if | ✅ data `6 no change`; app shows only the known DNS zone group noise (below) |
| Teardown with the database lock in place | ✅ both endpoints, VNet and NSGs deleted; 0 A records left; data tier intact |

**Problems I found and fixed**

1. **SQL region restriction and a reserved name**: see [INC-001](docs/incidents/INC-001-sql-region-restricted.md).
2. **Lock blocked endpoint teardown**: see [INC-002](docs/incidents/INC-002-lock-blocks-private-endpoint-teardown.md).
3. **A test that didn't test what I meant.** My first "public access is blocked" check used a SQL login, and the
   gateway rejected the login type before it ever evaluated the network rule. That proved Entra-only auth, not the
   network block. I reran the check with a valid Entra token from a `lark-sql-admins` member, which reaches the
   network rule, and got error 47073. A test only proves what it actually exercises.
4. **What-if drift.** The database's `createMode` is write-only (Azure never returns it), so I removed it from the
   template, since `Default` is what Azure uses anyway. The private endpoints' `isIPv6EnabledPrivateEndpoint` is
   returned by Azure but missing from Bicep's type definitions, so I declare it and suppress the type warning with a
   comment explaining why.

**Known what-if noise (accepted):** each private endpoint's DNS zone group shows
`- etag / id / properties.provisioningState / type` under `privateDnsZoneConfigs`. These are read-only properties
Azure adds to every zone config, and a template can't declare them. They don't indicate drift.

## Cost

| Item | Running cost |
|---|---|
| SQL database (free tier, AutoPause at the limit) | $0 |
| Key Vault (idle) | ~$0 |
| Private DNS zones (2, persistent) | ~$1.26/month |
| Private endpoints (2) | ~$0.01/hr each, only while a session is running |
| Budget alert | $5/month on both resource groups |

## Teardown

At the end of every session I run:

```powershell
./scripts/Remove-LarkAppResources.ps1 -WhatIf   # preview
./scripts/Remove-LarkAppResources.ps1           # delete and verify
```

It removes the DNS zone links, then everything inside `rg-lark-app` in dependency order, and verifies the group is
empty. `rg-lark-data` stays: it holds the data and costs about $0 when idle.
