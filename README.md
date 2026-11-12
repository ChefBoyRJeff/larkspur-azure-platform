# Larkspur Logistics Azure Platform

> **Status:** in progress (M2: network next). See [docs/plan.md](docs/plan.md).

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
| M2–M9 | Not started | |

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
