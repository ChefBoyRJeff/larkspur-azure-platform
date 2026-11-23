# Cost report

**The whole platform has cost $1.68 in actual charges from 11-01-2026 to 11-22-2026**, a third of its $5/month budget,
across M0–M8 (11-12 to 11-22), including every deploy/teardown session. $0.34 of that was one planned, one-off item:
the M7 restored database copy. Everything else matches the design: persistent pieces cost cents, and session pieces
cost only while a session runs.

Source: Cost Management Query API (`ActualCost`, `api-version=2026-06-01`), run 11-22-2026 08:36 PM EST, filtered to
`rg-lark-*`. Cost data lags about a day, so the 11-22 session may be only partly included.

## Actual cost by resource group and service

| Resource group | Service | Actual cost (USD) | What it is |
|---|---|---|---|
| `rg-lark-data` | SQL Database | 0.35 | **The M7 restored copy**, not the live database (below) |
| `rg-lark-data` | Azure DNS | 0.32 | The two persistent private DNS zones |
| `rg-lark-data` | Key Vault, Azure Monitor, Log Analytics | 0.00 | Within free allowances |
| `rg-lark-app-infra` | Load Balancer | 0.48 | The Container Apps environment's Standard Load Balancer, only while a session runs |
| `rg-lark-app-infra` | Virtual Network | 0.09 | Its public IPs |
| `rg-lark-app` | Virtual Network | 0.43 | The two private endpoints, only while a session runs |
| `rg-lark-app` | Azure Monitor | 0.01 | The session's 5xx log search alert |
| | **Total** | **1.68** | |

No Container Apps line appears at all: the API and jobs stayed inside the monthly free grant.

**The SQL charge, traced to the resource and meter.** Grouped by resource and meter, all of it is on 11-17-2026 on
`sqldb-lark-tracking-restore`: vCore $0.33 and General Purpose Data Stored $0.02. `sqldb-lark-tracking`, the live
free-tier database, cost **$0.00**. Restores can't target the free offer, so the M7 point-in-time restore created a
paid General Purpose serverless copy; it existed about 45 minutes, and I'd estimated "under $0.50".

## Against the plan's estimates

| Item | Plan estimate | Actual | Verdict |
|---|---|---|---|
| SQL database (free tier) | $0 | $0.00 | ✅ As designed |
| Private DNS zones (2) | ~$1.26/month | $0.32 in 11 days | ✅ Consistent (prorated) |
| Private endpoints (2) | ~$0.01/hr each, session only | $0.43 | ✅ Session hours only |
| Environment infrastructure (load balancer + public IPs) | ~$0.035–0.04/hr, session only | $0.57 | ✅ Session hours only; the one cost outside Container Apps' own billing, which is why its group is in the budget (M4a) |
| Container Apps | $0 within the free grant | $0 (no line item) | ✅ Including INC-010's `minReplicas: 1` sessions |
| Key Vault, alerts, Log Analytics | Pennies | $0.01 | ✅ |
| M7 restored copy (one-off) | Under $0.50 | $0.34 | ✅ |

## Free allowances

| Allowance | Used this month | Notes |
|---|---|---|
| SQL free tier: 100,000 vCore-seconds | 19,950 (80,050 left at 03:45 PM on 11-22) | INC-010 showed how fast this goes if the database never pauses: about 1,468/hour |
| Log Analytics | Within the free ingestion allowance | 0.1 GB/day cap on `log-lark` |
| Container Apps grant: 180,000 vCPU-s, 360,000 GiB-s, 2M requests | Not itemized by Azure | No charge appeared, so usage stayed within it |

## Budget

`budget-larkspur-platform`: $5/month on `rg-lark-data`, `rg-lark-app` and `rg-lark-app-infra`, with email alerts.
On 11-22 it reported **$1.48** current spend against the query's **$1.68**. Both cover the same three groups; I
haven't confirmed why they differ (most likely the budget's figure refreshes on a different schedule), so I treat
the higher number as the real one.

## What kept it low

- **Session-based design.** The app stack is deployed for a session and torn down after, and teardown proves
  `rg-lark-app` is empty and `rg-lark-app-infra` is gone (INC-004). The hourly items (load balancer, public IPs, private
  endpoints) only exist while I'm working.
- **Persistent tier sized to cost nearly nothing idle:** free-tier SQL that auto-pauses, Key Vault, DNS zones, a
  capped workspace.
- **Prices checked before building** (M0, Retail Prices API), and the budget covers the Container Apps managed group,
  which a default `ME_…` name would have hidden.
- **The incidents that touched cost were caught early:** INC-010 (a database that never paused) and M7's paid restore
  copy, deleted after the drill.

## Steady state

- **Idle (no session):** about $1.26/month, the two DNS zones. SQL, Key Vault and Log Analytics round to $0.
- **Per session hour:** roughly $0.06 (private endpoints ~$0.02 + environment infrastructure ~$0.035–0.04), plus free
  SQL vCore-seconds while the database is awake.
- **One-off drills:** a point-in-time restore costs real money ($0.34 here), because the copy can't be free tier.
