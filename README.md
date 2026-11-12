# Larkspur Logistics Azure Platform

> **Status:** in progress (M3: data and secrets next). See [docs/plan.md](docs/plan.md).

## Scenario

Larkspur Logistics is a **fictional** regional freight carrier with an HQ and several depots. This repository builds
and operates the Azure platform behind its customer shipment-tracking API: private data access, passwordless
identity, pipeline-only deployments, monitoring, tested recovery and policy guardrails.

This is a personal portfolio project that I design, build and operate end to end on my own Azure subscription. It is
a small, single-subscription landing zone run with production practices. It is not Microsoft's enterprise-scale
landing zone architecture, and it is not a production system serving real customers.

## Scope

- Governance: Azure Policy, tags, resource locks, budgets, Entra groups with least-privilege RBAC
- Network: VNet, NSGs, private endpoints, private DNS
- Data and secrets: Azure SQL Database (free tier, Entra-only auth), Key Vault (RBAC)
- App: Azure Container Apps with a managed identity
- CI/CD: GitHub Actions with OIDC, what-if on pull requests, approval-gated deploys
- Operations: Log Analytics, alerts, a workbook, tested restores and incident runbooks

Full sections (architecture diagram, deployment, verification, incident reports, cleanup) are added as each
milestone is delivered and verified.

## Progress

| Milestone | Status | Records |
|---|---|---|
| M0 Prerequisites | ✅ Delivered 2026-11-12 | [`docs/evidence/m0-*`](docs/evidence/) |
| M1 Governance | ✅ Delivered 2026-11-12 | [`docs/evidence/m1-*`](docs/evidence/) |
| M2 Network | ✅ Delivered 2026-11-12 | [`docs/evidence/m2-*`](docs/evidence/) |
| M3–M9 | Not started | |

### M0: Prerequisites

- **Providers:** all 8 required resource providers registered.
- **Existing policy:** the subscription's `deny-costly-resources` assignment (built-in *Not allowed resource types*,
  from my hub-spoke project) blocks gateways, firewalls, Bastion, NAT, Application Gateway, ExpressRoute, DDoS and
  vWAN hubs. Nothing in this design uses those types, so no exemption is needed.
- **Prices (eastus, retail):** Container Apps bills $0.10/hr for *Environment Management Hour*, *Dedicated Plan
  Management* and *Environment Private Endpoint*. The design avoids all three, and M4 must prove it in Cost Analysis.
  SQL serverless General Purpose is $0.52/vCore-hour beyond the free tier. Log Analytics ingestion is free for the
  first 5 GB, then $2.30/GB. A private DNS zone is $0.63/month, so the zones live in the persistent resource group.
- **Budget:** $5/month on `rg-lark-data` and `rg-lark-app`, deployed before either group existed.
- **What-if false positive:** the post-deploy what-if reported `Modify` on the budget's `contactEmails`, because
  what-if can't evaluate `@secure()` parameter values and shows the expression instead. Comparing SHA-256 hashes of
  the deployed and local email values showed all three notifications match, so it is noise, not drift. `@secure()`
  stays, because removing it would write a personal email address into deployment history.

### M1: Governance

**Delivered** (`infra/governance/`): both resource groups with standard tags; policy assignments at resource-group
scope (require `costCenter` tag, allowed locations `eastus`, and deny Azure SQL public network access in
`rg-lark-data`); Entra security groups `lark-ops` and `lark-dev` (created in the portal) with least-privilege RBAC.

| Group | rg-lark-data | rg-lark-app | Why |
|---|---|---|---|
| lark-ops | Reader, Monitoring Contributor | Reader | Operate alerts and workbooks without touching data or secrets |
| lark-dev | none | Reader | Changes ship through the pipeline, not the portal |

**Key decisions**

- Policies are scoped to the two Larkspur resource groups, not the subscription, because the subscription also
  hosts my other projects; a subscription-wide tag rule would deny their redeployments.
- RBAC goes to groups, so access changes are membership changes, not role-assignment changes.
- The `CanNotDelete` lock moved from the whole `rg-lark-data` group to the SQL server and Key Vault (M3): a group
  lock also locks child resources and would block the per-session teardown of private DNS zone VNet links.

**Verification**

| Check | Expected | Result |
|---|---|---|
| NSG without `costCenter` tag (eastus) | Denied | ✅ `RequestDisallowedByPolicy`: "Every Larkspur resource needs a costCenter tag…" |
| NSG with tag in `westus` | Denied | ✅ `RequestDisallowedByPolicy`: "Larkspur resources must be deployed to: eastus." |
| NSG with tag in `eastus` | Allowed | ✅ Created, then deleted |
| Re-run what-if after deploy | NoChange | ✅ `11 no change` (after the fix below) |

The custom non-compliance messages written in Bicep appear directly in the deny error, so whoever hits a guardrail
learns the rule from the error itself.

**Problem found and fixed: what-if drift on every run.** The first post-deploy what-if reported `Modify` on all five
policy assignments: `- properties.definitionVersion: "1.*.*"`. Azure now versions built-in policy definitions and
stores `1.*.*` (latest 1.x) when an assignment doesn't specify one. The code never declared it, so every what-if
proposed removing it. Fix: moved to API `2024-04-01` (the first version with `definitionVersion`) and declared
`definitionVersion: '1.*.*'`. Re-run: `11 no change`. Pinning the major version also means a breaking 2.x of a
built-in policy can't silently change these guardrails.

### M2: Network

**Delivered**

- `infra/data/` → `rg-lark-data`: private DNS zones `privatelink.database.windows.net` and
  `privatelink.vaultcore.azure.net` (persistent, shared platform service).
- `infra/app/` → `rg-lark-app`: `vnet-lark` (10.60.0.0/16) with `snet-aca` (10.60.0.0/27, delegated to
  `Microsoft.App/environments`) and `snet-pe` (10.60.1.0/27), an NSG on each, and VNet links into both zones.
- `scripts/Remove-LarkAppResources.ps1`: end-of-session teardown.

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

- **Two stacks split by lifecycle.** DNS zones are persistent and shared; the VNet and everything in it are rebuilt
  each session. The VNet links are children of the zones, so they deploy into `rg-lark-data` from the app stack.
- **NSG enforcement for private endpoints is explicitly enabled** (`privateEndpointNetworkPolicies:
  NetworkSecurityGroupEnabled`). Without it, Azure ignores NSG rules for traffic to private endpoints, and the
  `nsg-lark-pe` rules would be decoration.
- **Explicit `Deny-VNet-Inbound` at 4000** on both NSGs. Azure's default `AllowVnetInBound` would let anything in
  the VNet, and later anything peered or connected over VPN (depots), reach the data path.
- **Private subnets** (`defaultOutboundAccess: false`): no implicit internet egress. M4 must verify the Container
  Apps environment's own outbound path still pulls images and reaches Entra ID.
- **Teardown empties `rg-lark-app` but keeps the group**, because the group carries the M1 policy and RBAC
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

**Problems found and fixed**

1. **What-if drift on `vnet-lark`.** The post-deploy what-if reported `- properties.privateEndpointVNetPolicies:
   "Disabled"`. Azure stores this VNet-level property (API 2024-03-01 and later) with a default, and the template
   didn't declare it. Fix: declared `privateEndpointVNetPolicies: 'Disabled'`.
2. **The first fix didn't reach the deployment.** The re-run still showed the drift. Checking the file actually used
   showed the old version (no `privateEndpointVNetPolicies` line, 6,291 bytes instead of 6,655), so the deployment
   had been run against stale code. After the corrected file was in place (verified by content and size), a full
   rebuild from code returned `5 no change`. Lesson: when a fix "doesn't work", verify the artifact that was
   deployed before changing the fix.
