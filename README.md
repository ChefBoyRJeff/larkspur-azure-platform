# Larkspur Logistics Azure Platform

> **Status:** in progress (M0: prerequisites). See [docs/plan.md](docs/plan.md).

## Scenario

Larkspur Logistics is a **fictional** regional freight carrier with an HQ and several depots. This repository builds
and operates the Azure platform behind its customer shipment-tracking API: private data access, passwordless
identity, pipeline-only deployments, monitoring, tested recovery and policy guardrails.

This is a hands-on lab: a small, single-subscription landing zone run with production practices. It is not
Microsoft's enterprise-scale landing zone architecture, and it is not a production system.

## Planned scope

- Governance: Azure Policy, tags, resource locks, budgets, Entra groups with least-privilege RBAC
- Network: VNet, NSGs, private endpoints, private DNS
- Data and secrets: Azure SQL Database (free tier, Entra-only auth), Key Vault (RBAC)
- App: Azure Container Apps with a managed identity
- CI/CD: GitHub Actions with OIDC, what-if on pull requests, approval-gated deploys
- Operations: Log Analytics, alerts, a workbook, tested restores and a scripted game day

Full sections (architecture diagram, deployment, verification, RCAs, cleanup) are added as each milestone is verified.
