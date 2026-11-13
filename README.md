# Larkspur Logistics Azure Platform

> **Status:** in progress. M0–M5 delivered; next is M6 (alerts, a workbook and cost alerts).
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
  Internet ──HTTPS──▶ public IP (rg-lark-app-infra, managed by Container Apps)
                           │
                          vnet-lark 10.60.0.0/16  (East US, rg-lark-app: rebuilt every session)
                          ├─ snet-aca 10.60.0.0/27   cae-lark (Container Apps, Consumption, external)
                          │                          ├─ ca-lark-tracking-api  API, identity id-lark-tracking-api
                          │                          ├─ job-lark-migrate      schema/seed/app user/secret, identity id-lark-migrator
                          │                          └─ job-lark-dnscheck     resolves the data tier from inside the VNet
                          └─ snet-pe  10.60.1.0/27   NSG: only snet-aca → 1433 / 443
                               ├─ pe-lark-sql 10.60.1.5 ──▶ sql-lark-… (Central US) ─ sqldb-lark-tracking (free tier, locked)
                               └─ pe-lark-kv  10.60.1.4 ──▶ kv-lark-… (East US, purge protection)

  rg-lark-data (persistent): SQL server + database, Key Vault, private DNS zones, log-lark (Log Analytics),
                             managed identities id-lark-tracking-api and id-lark-migrator
  Image: ghcr.io/chefboyrjeff/larkspur-tracking-api (public GHCR package, built by GitHub Actions)
  Pipeline: GitHub Actions with OIDC (no secrets). Pull requests: validate as gh-lark-plan (read + what-if only).
            deploy / teardown: manual, behind my approval on the "production" environment, as gh-lark-deploy.
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
app/
  larkspur/                    FastAPI shipment-tracking API + migration entry point (python -m larkspur.migrate)
  tests/                       unit tests (run in CI without Azure)
  Dockerfile                   Python 3.12 slim + ODBC Driver 18, non-root
.github/workflows/
  app-image.yml                test, build and publish the image to GHCR
  validate.yml                 pull requests: lint, type checks, what-if, guardrail (plan identity can't deploy)
  deploy.yml                   start a session: verify image, deploy, migrate, smoke tests, idempotency (approval)
  teardown.yml                 end a session: remove the app stack and prove nothing is left billing (approval)
identity/                      custom role definitions for the pipeline identities (JSON)
infra/
  budget.bicep                 $5/month budget on both resource groups (subscription scope)
  governance/                  resource groups, policy assignments, group RBAC (subscription scope)
  shared/naming.bicep          globally unique names, shared by both stacks
  data/                        rg-lark-data: private DNS zones, SQL + database, Key Vault, Log Analytics, identities (persistent)
  app/                         rg-lark-app: VNet, NSGs, DNS links, private endpoints, Container Apps (rebuilt each session)
scripts/
  Remove-LarkAppResources.ps1  end-of-session teardown (run by teardown.yml, or by me locally)
  Initialize-LarkPipeline.ps1  one-time admin setup: custom roles, OIDC app registrations, role assignments
  whatif-drift.jq              idempotency filter: removes documented what-if noise, fails on anything else
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
| M4a Container Apps environment | ✅ Delivered 11-12-2026 | [`docs/evidence/m4a-*`](docs/evidence/) |
| M4b Shipment-tracking API | ✅ Delivered 11-13-2026 | [`docs/evidence/m4b-*`](docs/evidence/) |
| M5 Deployment pipeline | ✅ Delivered 11-13-2026 | [`docs/evidence/m5-*`](docs/evidence/), [INC-003](docs/incidents/INC-003-pipeline-deploy-linked-scope-and-pending-delete.md), [INC-004](docs/incidents/INC-004-teardown-false-positive-verification.md) |
| M6–M9 | Not started | |

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

### M4a: Container Apps environment

**What I built** (`infra/app/modules/container-apps.bicep`, `infra/data/modules/log-analytics.bicep`)

- `cae-lark`: a workload-profiles Container Apps environment (Consumption profile only) injected into `snet-aca`,
  external, sending logs to `log-lark`.
- `ca-lark-hello`: Microsoft's public quickstart image with external ingress, scaling 0–1. It's a stand-in that
  proves ingress and egress before my own code runs on the platform.
- `job-lark-dnscheck`: a one-shot job that resolves the SQL and Key Vault names from inside the VNet and prints the
  answers.
- `log-lark`: a Log Analytics workspace in `rg-lark-data` with a 0.1 GB/day cap and 30-day retention, so session
  logs survive teardown.

**Key decisions**

- **Consumption only, no environment private endpoint.** Apps scale to zero and stay inside the monthly free grant,
  and there's no dedicated-plan "management hour" charge (M0 pricing).
- **I named the managed resource group.** A VNet-integrated environment creates its own group with a Standard Load
  Balancer and public IPs, billed separately from Container Apps. Under the default `ME_…` name my budget (which
  filters by resource group) wouldn't have seen that cost, so I set `infrastructureResourceGroup` to
  `rg-lark-app-infra` and added it to the budget.
- **Egress from a private subnet.** In M2 I made the subnets private (`defaultOutboundAccess: false`) and flagged a
  risk that the environment couldn't pull images. The environment's own load balancer provides the outbound path,
  and the image pull succeeded.
- **A job to prove DNS.** My PC resolves the SQL name to a public IP, so only something inside `vnet-lark` can show
  the private zone's answer. A job is the right shape for that: it runs once and exits. The database migration in M4b
  uses the same pattern.
- **Log Analytics moved forward from M6**, because the environment needs a log destination and the DNS check reads
  its output from the logs.

**Verification**

| Check | Result |
|---|---|
| Environment | ✅ `Succeeded`, external, Consumption, logs to `log-lark`, managed group `rg-lark-app-infra` |
| Managed group | ✅ load balancer + public IP, both carrying my `costCenter` tag (copied from the environment) |
| Budget | ✅ covers `rg-lark-data`, `rg-lark-app`, `rg-lark-app-infra` |
| Ingress and egress | ✅ HTTP 200 from my PC; the image was pulled through the private subnet |
| DNS from inside the VNet | ✅ `sql-lark-….database.windows.net -> 10.60.1.5`, `kv-lark-….vault.azure.net -> 10.60.1.4` (match the endpoint NICs) |
| Teardown | ✅ apps, job, environment, endpoints, VNet and NSGs deleted; `rg-lark-app-infra` removed by Azure; data tier intact |

Log Analytics stores times in UTC; the DNS check ran at 02:45 UTC, which is 11-12-2026 09:45 PM EST.

**Operational note:** deleting the environment is slow. My teardown took 29 minutes (09:57 PM–10:26 PM EST), most of it
waiting for the environment and its managed group to go away. The environment's load balancer and IPs bill until
then, so I start teardown as soon as I'm done with a session.

**What-if after deploy**

| Item | Classification |
|---|---|
| Environment `appLogsConfiguration.customerId` shown as `[reference(...)]` | What-if limitation: it can't evaluate a reference into another resource group (same class as the `@secure()` noise in M0). Accepted. |
| Environment `peerAuthentication` / `peerTrafficConfiguration` (`false`) | Defaults the template doesn't declare yet. I'm declaring them in M4b. |
| `ca-lark-hello` `traffic`, `maxInactiveRevisions`, `exposedPort`, `runningStatus` | Defaults plus a read-only status on the stand-in app. The M4b app module declares the settable ones. |
| DNS zone groups | Known read-only noise (see M3) |

### M4b: Shipment-tracking API

**What I built**

- `app/`: a small FastAPI service. `GET /healthz` checks the process is alive, `GET /readyz` checks private DNS, SQL
  and Key Vault through the managed identity, and `GET /shipments/{trackingNumber}` returns a shipment. Tracking
  numbers are validated (`LRK` + 6 digits) before any database call.
- `app/larkspur/migrate.py`: an idempotent migration that runs as a Container Apps job. It creates `dbo.Shipments`,
  seeds 5 synthetic shipments, creates the app's database user with `SELECT` on that one table, and generates the
  carrier API key in Key Vault without ever printing it.
- `.github/workflows/app-image.yml`: runs the unit tests, builds the image and publishes it to GitHub Container
  Registry. It needs no Azure credentials.
- `infra/data/modules/identities.bicep`: persistent user-assigned identities `id-lark-tracking-api` (Key Vault
  Secrets User) and `id-lark-migrator` (Key Vault Secrets Officer, and a member of `lark-sql-admins`).
- `infra/app/modules/container-apps.bicep`: `ca-lark-tracking-api` and `job-lark-migrate`, both running my image.

**Key decisions**

- **No passwords anywhere.** The app gets an Entra token from its managed identity and passes it to the ODBC
  driver. There's no connection-string secret to store, rotate or leak.
- **Two identities, two blast radiuses.** The API can only read shipments and read secrets. Database administration
  belongs to the migrator, which is an admin only through the `lark-sql-admins` group. If the API were compromised,
  it couldn't change or drop data.
- **The app's database user is created by SID** (`CREATE USER … WITH SID = <client ID>, TYPE = E`). The usual
  `FROM EXTERNAL PROVIDER` form makes SQL look the identity up in Microsoft Graph, which would mean granting the SQL
  server directory-read permissions. Creating the user from the client ID avoids that.
- **Persistent identities in `rg-lark-data`.** The app stack is rebuilt every session; an identity rebuilt with it
  would get a new client ID each time, leaving stale database users and role assignments. The migration also
  detects a client-ID mismatch and recreates the user if an identity is ever replaced.
- **Migrations run as a job inside the VNet.** The database accepts no public connections, so schema changes run
  from inside `vnet-lark`, the same pattern I proved with the DNS check in M4a.
- **Probes hit `/healthz`, never `/readyz`.** A probe that touched the database every few seconds would stop the
  free-tier database from auto-pausing and would fail every time it resumed.
- **Public GHCR image instead of Azure Container Registry.** The image holds no secrets, and a public GHCR package
  costs nothing, versus about $0.17/day for Container Registry Basic.

**Verification** (11-13-2026)

| Check | Result |
|---|---|
| Unit tests in GitHub Actions | ✅ 5 passed; image published as `:main` and `:<commit SHA>` |
| Anonymous pull from GHCR | ✅ HTTP 200 (package is public) |
| Identities and roles | ✅ both identities in `rg-lark-data`; each holds only its own Key Vault role |
| `lark-sql-admins` | ✅ me + `id-lark-migrator` |
| Migration job (08:51 AM EST) | ✅ schema ok, 5 shipments seeded, `id-lark-tracking-api: SELECT on Shipments`, secret created, completed |
| `GET /healthz` | ✅ 200 |
| `GET /readyz` | ✅ 200: SQL resolves to 10.60.1.5 (private endpoint), 5 shipments, secret present (value never returned) |
| `GET /shipments/LRK100001` | ✅ 200 with the shipment, read by the managed identity over the private path |
| `GET /shipments/LRK999999` | ✅ 404 |
| `GET /shipments/not-a-number` | ✅ 400, rejected before any database call |
| What-if after deploy | ✅ no real drift (below); the M4a environment drift is gone |

**What-if after deploy**

| Item | Classification |
|---|---|
| `AZURE_CLIENT_ID` / `APP_IDENTITY_CLIENT_ID` on the app and job, environment `customerId` | What-if can't resolve references into another resource group and shows the expression. The deployed values are correct: both identities authenticated. Accepted. |
| App `exposedPort: 0`, `runningStatus` | `exposedPort` applies only to TCP ingress; `runningStatus` is read-only. Accepted. |
| DNS zone groups | Known read-only noise (M3) |

**Still to confirm:** Cost Analysis data lags about a day, so I'll check the next day that `rg-lark-app-infra` and
Container Apps show no management-hour charge.

### M5: Deployment pipeline

**What I built**

- `.github/workflows/validate.yml`: runs on every pull request that touches infrastructure. It lints every Bicep
  entry point against the rules I set to `error` in `bicepconfig.json`, type-checks every parameter file, runs
  what-if against `rg-lark-app` and posts it to the run summary, and runs a **guardrail**: a real deployment attempt
  as the plan identity that must be refused.
- `.github/workflows/deploy.yml`: starts a session. It resolves the image tag, checks the image exists in GHCR,
  deploys, runs the migration job, smoke-tests the API from the internet, then runs what-if again and fails on any
  real drift.
- `.github/workflows/teardown.yml`: ends a session with my teardown script, then re-checks independently that
  `rg-lark-app` is empty and `rg-lark-app-infra` is gone.
- `scripts/Initialize-LarkPipeline.ps1`: the one-time admin setup. It creates three custom roles, two app
  registrations with GitHub OIDC federated credentials, and the role assignments. It's idempotent, syncs the roles
  from their JSON files, and writes a log with names, roles and scopes only.
- `scripts/whatif-drift.jq`: the idempotency filter. Each rule removes one documented kind of what-if noise;
  anything left is drift and fails the deploy.

**Identities** (no client secrets or certificates on either; both show `secrets=0 certificates=0`)

| Identity | Trusted only for | Roles |
|---|---|---|
| `gh-lark-plan` | `pull_request` | Larkspur What-If Reader on `rg-lark-app` and `rg-lark-data`: `*/read`, what-if and validate. No `deployments/write`. |
| `gh-lark-deploy` | `environment:production` (my approval required, `main` only) | Contributor on `rg-lark-app`; Larkspur Data-Tier Integrator on `rg-lark-data`; Larkspur Group Reader on the subscription |

Larkspur Data-Tier Integrator covers exactly what the app stack touches in the data tier: the VNet links, private
DNS records, auto-approval of the SQL and Key Vault private endpoint connections, attaching the two managed
identities, and pointing a diagnostic setting at `log-lark`. It can't change or delete the database, the vault, its
secrets, the identities or the zones. Larkspur Group Reader has one action, `resourceGroups/read`, so teardown can
prove the Container Apps managed group is gone (INC-004).

**Key decisions**

- **OIDC instead of a client secret.** GitHub issues a short-lived token for each job and Microsoft Entra ID trusts it
  by its subject. There's no secret to store, rotate or leak. The four values I keep as GitHub secrets (tenant,
  subscription and two client IDs) are identifiers, not passwords; I store them as secrets to keep them out of logs.
- **Trust is scoped by subject.** My repository was created after GitHub switched to immutable OIDC subjects, so the
  subject includes the owner and repository IDs (`repo:ChefBoyRJeff@<ownerId>/larkspur-azure-platform@<repoId>:...`).
  A renamed or recreated repository with the same name can't reuse the trust. `gh-lark-plan` trusts pull requests
  only; `gh-lark-deploy` trusts the `production` environment only, which needs my approval and allows only `main`.
- **Two identities, and I prove the read-only one is read-only.** A role that's "supposed to" be read-only isn't a
  control until it's tested. The guardrail job tries a real deployment as `gh-lark-plan` on every pull request and
  fails the PR if it isn't refused with `deployments/write`.
- **Deploys are started manually, not on every push.** The app stack is torn down after every session for cost, so a
  push to `main` has nothing running to update. A session starts with `deploy` and ends with `teardown`, both behind
  my approval.
- **The pipeline deploys only the app stack.** Governance and the data tier hold policies, locks, role assignments and
  data. They stay deployed by me, and the deploy identity gets only what the app stack needs in `rg-lark-data`.
- **The image is pinned to a commit SHA and checked before Azure is touched.** By default the workflow deploys the
  last commit that changed `app/`, because infrastructure-only commits don't produce a new image. It confirms that
  tag exists in GHCR first, so a typo can't half-deploy the stack.
- **Logs through an Azure Monitor diagnostic setting.** The M4a setup put the workspace key in the template through
  `listKeys()`, so the key went through the deployment and even what-if had to read it. With a diagnostic setting the
  key never appears in the template or the deployment history. The deploy identity still needs
  `workspaces/sharedKeys/action` on `log-lark`, because Azure checks the destination too (INC-003).
- **Idempotency is a gate, not a report.** After every deploy, what-if must show no real change. The filter's rules are
  documented below; when the check found real drift on the new diagnostic setting, I fixed the template instead of
  adding a rule.
- **One targeted retry.** `deploy` retries once, only for Azure's "pending delete operation" conflict (INC-003). Every
  other failure stops the run with the full error message.

**What-if noise the idempotency filter removes** (each one investigated earlier)

| Rule | Why it's noise |
|---|---|
| DNS zone groups: `etag`, `id`, `provisioningState`, `type` inside `privateDnsZoneConfigs` | Read-only properties Azure returns (M3) |
| `properties.runningStatus` on the app | Read-only status (M4b) |
| `properties.configuration.ingress.exposedPort` | TCP-only setting Azure stores as 0 for HTTP apps (M4b) |
| Values shown as `[reference(...)]` | What-if can't resolve references into another resource group; the smoke tests prove the deployed values (M4a/M4b) |

**Verification** (11-13-2026)

| Check | Result |
|---|---|
| Pipeline identities | ✅ 3 custom roles, 2 app registrations with 1 federated credential each, 0 secrets and 0 certificates, every assignment scoped as designed ([`m5-01`](docs/evidence/m5-01-pipeline-identity.txt), [`m5-08`](docs/evidence/m5-08-group-reader.txt)) |
| PR #1 `validate` | ✅ lint and build; what-if as `gh-lark-plan`: 14 to create, 9 to ignore; guardrail refused with `deployments/write` ([`m5-02`](docs/evidence/m5-02-validate-pr1.txt)) |
| Deploy run 1 | ❌ linked-scope permission and a pending delete (INC-003) ([`m5-03`](docs/evidence/m5-03-deploy-run1-failed.txt)) |
| Deploy run 2 | ✅ deploy, migration and smoke tests; ❌ idempotency: 4 real changes on the new diagnostic setting ([`m5-05`](docs/evidence/m5-05-deploy-run2-drift.txt)) |
| Deploy run 3 | ✅ every step, **Idempotency: PASS** ([`m5-06`](docs/evidence/m5-06-deploy-run3-pass.txt)) |
| Smoke tests (run 3) | ✅ `/healthz` 200; `/readyz` 200 with SQL at 10.60.1.4 (private endpoint), 5 shipments, secret present; LRK100001 200; LRK999999 404; bad input 400 |
| Teardown run 1 | ✅ everything deleted; ❌ the managed-group check was refused but reported "gone" (INC-004) ([`m5-07`](docs/evidence/m5-07-teardown-run1-forbidden.txt)) |
| Teardown run 2 | ✅ `rg-lark-app` empty, `rg-lark-app-infra` gone, proven by a real answer ([`m5-09`](docs/evidence/m5-09-teardown-run2-verified.txt)) |
| Log routing | ✅ rows in the resource-specific `ContainerAppConsoleLogs` table, after Azure's documented activation time of up to 90 minutes for a new diagnostic setting ([`m5-10`](docs/evidence/m5-10-log-routing.txt)) |

**What I'd do differently in production:** branch protection on `main` (required pull request and required
`validate` checks), a second approver instead of approving my own deploys, and a separate non-production
environment that deploys automatically on merge.

## Cost

| Item | Running cost |
|---|---|
| SQL database (free tier, AutoPause at the limit) | $0 |
| Key Vault (idle) | ~$0 |
| Private DNS zones (2, persistent) | ~$1.26/month |
| Private endpoints (2) | ~$0.01/hr each, only while a session is running |
| Container Apps environment infrastructure (load balancer + 2 public IPs) | ~$0.035–0.04/hr (estimate), only while a session is running |
| Container Apps usage | within the monthly free grant (scale to zero) |
| Container image (public GHCR package) | $0 |
| Managed identities | $0 |
| Log Analytics | within the free ingestion allowance; 0.1 GB/day cap |
| Budget alert | $5/month on both resource groups |
| GitHub Actions | $0 (public repository, GitHub-hosted runners) |

## Teardown

At the end of every session I run the **teardown** workflow (Actions → teardown → Run workflow, then approve). It
runs the same script I can run locally:

```powershell
./scripts/Remove-LarkAppResources.ps1 -WhatIf   # preview
./scripts/Remove-LarkAppResources.ps1           # delete and verify
```

It removes the DNS zone links, then everything inside `rg-lark-app` in dependency order (apps and jobs, environment,
private endpoints, VNet, NSGs, identities), verifies the group is empty, and waits up to 10 minutes to confirm Azure
has removed `rg-lark-app-infra`. If it can't check, or the group is still there, it fails instead of reporting
success (INC-004). `rg-lark-data` stays: it holds the data and logs and costs about $0 when idle.
