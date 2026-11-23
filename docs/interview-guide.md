# Interview guide

How I talk about this project. It's a **hands-on portfolio project** on my own Azure subscription for a fictional
company, not production experience, and I say so. Every answer below is backed by something in this repository:
a template, a workflow run, an evidence file or an incident report.

## 3–5 minute walkthrough

1. **Problem (30 s).** "Larkspur is a fictional freight carrier. Customers look up shipments online. The company
   wants the API's data side private, passwordless, deployed only through a pipeline, monitored, recoverable, and
   cheap enough to run on a $5 budget."
2. **Architecture (60 s).** "A Container App in a VNet serves the API. SQL and Key Vault have public access turned
   off and are reachable only through private endpoints with private DNS. The app authenticates with a managed
   identity, so there are no passwords anywhere. Azure Policy at resource-group scope enforces tags, regions and no
   public SQL."
3. **Delivery (45 s).** "GitHub Actions with OIDC, so no stored secrets. Every pull request runs lint, a what-if and a
   guardrail proving the read-only identity can't deploy, and all three are required to merge. A deploy needs my
   approval, runs a migration inside the VNet, smoke-tests from the internet, and fails if a second what-if finds
   drift."
4. **Operations (75 s).** "Then I broke it on purpose, five ways, and worked each like on-call: a deleted DNS link, a
   removed Key Vault role, a portal edit that gave the app the wrong identity, a pull request that broke policy, and a
   keep-warm job that stopped the free database from ever pausing. Each one has an incident report with the
   hypotheses I ruled out, the root cause, the fix through the pipeline, and what I changed so it can't recur."
5. **Recovery (30 s).** "I restored the database to two seconds before a simulated bad update with zero rows lost,
   recovered a deleted secret from soft delete, and rolled back a bad release by redeploying the last good image."
6. **Cost (15 s).** "The app stack is torn down every session, and teardown proves nothing billable is left. The whole
   project cost $1.68 in actual charges, and a third of that was the one paid restore drill."

## 10-minute deep dive

| Minutes | Topic | Show |
|---|---|---|
| 2 | The network: two subnets, NSG rules between them, private endpoints, the DNS zones, and what my PC resolves vs what the app resolves | README diagram; `Test-LarkPrivateDns.ps1` |
| 2 | Identity: groups for people, managed identities for workloads, two OIDC identities for the pipeline, and the custom roles | M5 table; `identity/` |
| 2 | The pipeline: `deploy.yml` step by step, the idempotency gate and its documented noise, the required checks on `main` | Workflow runs |
| 3 | One incident in depth, with its hypothesis table: INC-008 (authentication) or INC-010 (cost) | `docs/incidents/` |
| 1 | What I'd change for production | README limitations |

## Likely questions and my answers

**Why private endpoints instead of firewall rules?** A firewall rule still leaves the service on a public endpoint.
A private endpoint gives it a private IP in my VNet, so public access can be turned off outright. I proved it: a valid
Entra token from the internet was refused with error 47073.

**How does the app reach SQL without a password?** A user-assigned managed identity. The app requests a token for
SQL and hands it to the ODBC driver; in the database the identity is a contained user with SELECT on one table.

**How do you tell authentication from authorization?** By the error. In INC-007 Key Vault returned a 403 naming my
API's object ID: Azure knew who it was and said no, so a role was missing. In INC-008 there was no 403, only
`CredentialUnavailableError`: the app asked for an identity it doesn't have, so no token was ever issued.

**Tell me about a time something didn't work.** INC-005: my first 5xx alert didn't fire during a real outage. I ruled
out four hypotheses and found the platform metric recorded 2 of at least 15 failed requests while the ingress log had
all of them, so I rebuilt it as a log search alert and proved it on a repeat.

**Tell me about a guardrail that didn't work.** INC-009: Azure Policy denied a pull request in its what-if, but the PR
still showed "Able to merge" because the check wasn't required. Before requiring it I removed the workflow's paths
filter (a skipped required check stays Pending forever) and required lint too (a job skipped after a failure counts
as passing).

**Tell me about a change that cost money.** INC-010: a keep-warm job called `/readyz` every 5 minutes, and `/readyz`
opens a SQL connection, so the free database never got its 15 idle minutes to pause. I proved it with metrics, stopped
the drain by deleting the job, and fixed it with `minReplicas: 1` plus a required lint guard. The design rule had been
in a code comment; now it's enforced.

**What is idempotency, and how do you enforce it?** Deploying the same code twice should change nothing. After every
deploy the pipeline runs what-if again and fails on anything beyond documented noise.

**What are its limits?** It only runs at deploy time, and what-if can't resolve some values, so INC-008's portal edit
looked like noise. The improvement I'd build next is a scheduled check that compares live values with the expected
ones.

**What are RTO and RPO, and what did you measure?** RTO is how long recovery takes; RPO is how much data you lose. My
point-in-time restore lost zero rows. The restore took 19 min 58 s, and the whole recovery 61 min 22 s, most of it
process time a runbook would cut.

**How do you control cost?** Prices checked before building, a budget before any resources, a free-tier database that
auto-pauses, compute only during sessions, and a teardown that fails if anything billable is left. Actual: $1.68.

**Why Container Apps and not AKS?** One small API needs VNet injection, managed identity and jobs, not a cluster to run.

**What would you do differently in production?** A second approver, a non-production environment that deploys on
merge, zone and geo redundancy for the database, an outside-in availability test that doesn't touch SQL, a drift
check between deploys, a burn-rate alert for the free database, and Owner as a break-glass role instead of my daily
account.

## Framing

- Say "in my portfolio project" or "in my lab", never "at work".
- Lead with the problem, show one diagram, tell one troubleshooting story with evidence.
- When I don't know, say how I'd find out: most of these answers started that way.
