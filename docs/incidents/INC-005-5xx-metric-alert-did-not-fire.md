# INC-005: The API 5xx alert didn't fire during a real outage

| | |
|---|---|
| **Date** | 11-15-2026, 12:56 PM–02:20 PM EST |
| **Milestone** | M6 (observability) |
| **Impact** | During a controlled failure the API returned 10 x HTTP 500 and the alert stayed silent for 15+ minutes. In a real outage nobody would have been paged. |
| **Status** | Resolved: the alert is now a log search alert on `ContainerAppHTTPLogs`, tested end to end (fired and resolved, both emails received) |

## Symptoms

For the controlled failure I set `Allow-SQL-From-App` on `nsg-lark-pe` to **Deny** in the portal, so the API couldn't
reach SQL. Ten parallel requests to `/shipments/LRK100001` all returned **HTTP 500 after 200 seconds** (the app's
SQL connection attempts timing out), finishing at 12:59 PM. `alert-lark-api-5xx` was a metric alert on the
`Requests` metric, filtered to `statusCodeCategory = 5xx`, firing at 5 or more in 5 minutes. It didn't fire in 15
checks (12:59 PM–01:14 PM), and no email arrived.

Evidence: [`m6-03-controlled-failure.txt`](../evidence/m6-03-controlled-failure.txt)

## Investigation

| Hypothesis | Check | Result |
|---|---|---|
| The dimension value doesn't match (`5xx` vs `5XX`) | Metric definition and recorded values | Ruled out: values are lowercase (`2xx`, `4xx`) |
| The rule isn't evaluating | `az monitor metrics alert show` | Ruled out: enabled, on `ca-lark-tracking-api`, `Total >= 5`, every minute over 5 minutes |
| The dimension split hides the data | `Requests` with no split, and split by revision | Ruled out: the unsplit total was also **2 requests in 2 hours** |
| The app wasn't running | `Replicas`, `RestartCount` | Ruled out: 1 replica during the smoke tests and the failures, 0 restarts |
| The logs saw what the metric missed | KQL on the resource-specific tables | **Confirmed**: `ContainerAppHTTPLogs` had 15 rows (5 smoke tests + 10 failures); `ContainerAppConsoleLogs` had exactly 10 access-log lines with HTTP 500 at 12:59 PM |

## Root cause

The `Requests` platform metric recorded **2 of at least 15 requests** that session. The alert evaluated correctly,
on a metric that didn't contain the failures. I couldn't find why the metric undercounts in this environment (a
Consumption workload profile app that scales to zero) in Microsoft's documentation, so I record it as observed
behavior, not an explained one. My mistake was building the alert on a signal I hadn't checked against known
traffic first.

## Remediation

- `alert-lark-api-5xx` is now a **log search alert** (`Microsoft.Insights/scheduledQueryRules`) over
  `ContainerAppHTTPLogs`, the ingress's own per-request log:
  `ContainerAppHTTPLogs | where ContainerAppName == "ca-lark-tracking-api" and StatusCode >= 500`,
  firing at 5 or more rows.
- **15-minute window, evaluated every 5 minutes.** A row is stamped with the request's start time but arrives after
  the request finishes (these took up to 200 seconds), so a 5-minute window could miss rows that land late.
- It's deployed with the app stack and deleted by teardown, so it's billed only while a session runs (about
  $1.50/month if it ran all month).
- I deleted the old metric alert from the running stack (an incremental deployment doesn't remove a resource taken
  out of the template), and teardown now deletes log search alerts as well as metric alerts.

Files: `infra/app/modules/alerts.bicep`, `infra/app/main.bicep`, `scripts/Remove-LarkAppResources.ps1`

## Verification

Same failure, repeated against the new alert ([`m6-04`](../evidence/m6-04-controlled-failure-log-alert.txt)):

| Time (EST) | Event |
|---|---|
| 01:52 PM | `Allow-SQL-From-App` set to Deny in the portal |
| 01:55 PM | 10 x HTTP 500 (166 seconds each) |
| 02:04 PM | **Fired** (Sev1); "Fired" email received |
| 02:12 PM | Rule set back to Allow in the portal; `/readyz` 200, shipments 200 and 404 |
| 02:20 PM | **Resolved** automatically; "Resolved" email received |

Detection took 9 minutes after the failing requests finished (12 minutes after the outage began): the 5-minute
evaluation interval, plus log ingestion, plus the time the failing requests themselves took.

## Prevention

- An alert isn't done until it has fired on a real, controlled failure. A green deployment only proves the rule
  exists.
- Before alerting on a signal, I check it against traffic I know about (the smoke tests are a free calibration).
- When a platform metric and a log disagree, the log with one row per request is the source of truth.
