# INC-010: A keep-warm job stopped the free SQL database from auto-pausing

| | |
|---|---|
| **Date** | 11-22-2026, 01:37 PM–03:50 PM EST |
| **Milestone** | M8 (operational incidents) |
| **Type** | Deliberate M8 incident: I merged a well-meant PR that added a scheduled "keep-warm" job calling `/readyz` every 5 minutes to avoid the API's cold start, then worked it as the platform owner |
| **Impact** | The free-tier database stayed **Online for the whole time the job ran** (it never paused in 34.5 minutes of observation; the baseline paused after 17). Measured burn about **1,468 vCore-seconds per hour**: left running, the remaining allowance would have lasted about **2.3 days**, after which the database locks **until 12-01-2026** (`freeLimitExhaustionBehavior: AutoPause`). No user-facing errors. |
| **Status** | Mitigated by deleting the job (02:55 PM); fixed by PR #20 (job removed, API `minReplicas: 1`, a required lint guard against `/readyz` in `infra/`); verified: the database paused 16.5 minutes after its last use **while the API stayed up** |

## Background: how the free database pauses

From Microsoft's free-tier documentation: the database **pauses automatically after 15 minutes of inactivity, and
that delay can't be changed**. Auto-pause only starts if, during the delay, there are no sessions and no user CPU,
and the pause itself takes 1–10 minutes once the conditions are met. Serverless consumes vCore-seconds whenever the
database is online, whatever the CPU.

Two things I measured instead of assuming ([`m8-13`](../evidence/m8-13-inc010-baseline.txt)):

- **The resource reports `autoPauseDelay: 60`, but the database paused after 17 minutes idle.** For a free-tier
  database the 60 is misleading; the fixed 15 minutes is what applies.
- **Free allowance before the incident:** 83,091 of 100,000 vCore-seconds left (12:39 PM). The metric is only
  emitted while the database is online, so the gaps in the series show when it was paused.

The design already knew the risk. Above the API's probes in `container-apps.bicep` (M4b):

```
// Probes hit /healthz (process only), never /readyz: probing the database would keep the free-tier database
// from auto-pausing and would fail every time it resumes from a pause.
```

## Symptoms

[`m8-14`](../evidence/m8-14-inc010-symptoms.txt)

- PR #19 ("Add keep-warm job to avoid API cold starts") passed all three required checks and was merged at
  02:09:08 PM. **Nothing in CI can see runtime cost behavior.**
- After the deploy, `job-lark-keepwarm` ran every 5 minutes (8 executions, all `LARK-KEEPWARM 200`).
- The database stayed **Online** for 34.5 minutes after the last other call (the smoke tests at 02:15:32 PM) and
  **never paused**. The baseline had paused at 17.
- **No alert fired, and none would have in time.** `alert-lark-sql-free-amount` fires below 10,000 remaining: at
  the measured rate, about 48 hours in, leaving about 7 hours before the lock.

## Investigation

[`m8-15`](../evidence/m8-15-inc010-diagnosis.txt)

| Hypothesis | Check | Result |
|---|---|---|
| H1: the keep-warm calls are the database's connections | SQL `connection_successful` per minute vs the job's 5-minute marks | **Confirmed.** 8 of 9 minutes with connections were 1–2 minutes after a keep-warm mark, 1 connection each; the 9th was the migrate job. Nothing else connected. |
| H2: the job keeps the API warm | API `Replicas` per minute | **Confirmed.** At least 1 replica every minute for 38 of 38 minutes. The job did what its author wanted; the way it did it (`/readyz`) pulled the database along. |
| H3: how fast is the allowance draining? | `free_amount_remaining`, keep-warm-only window | About **1,468 vCore-seconds per hour** over 30 minutes. The metric updates unevenly (one 15-minute slot used 652, the next 82), so this is an estimate. |

Microsoft's documented way to find what blocks auto-pause is to query `sys.dm_exec_sessions`, but that opens a
session of its own. Correlating the connection metric with the job schedule answered the question without touching
the database.

## Root cause

The keep-warm job called `/readyz`, and `/readyz` runs `SELECT COUNT(*) FROM dbo.Shipments`. A SQL connection every 5
minutes means the database never gets the 15 idle minutes it needs, so it never pauses and burns vCore-seconds
around the clock. The PR broke a design rule that was written in a comment two screens away in the same file, and
nothing enforced it.

**Why reverting the code alone wouldn't have fixed it:** the pipeline deploys in ARM's default **Incremental** mode,
which doesn't delete resources that disappear from the template. Removing the job from Bicep would have left it
running in Azure.

## Mitigation and fix

[`m8-16`](../evidence/m8-16-inc010-mitigation.txt), [`m8-17`](../evidence/m8-17-inc010-fix.txt)

1. **Mitigate (02:55:21 PM):** I deleted `job-lark-keepwarm` as Owner. The run that had started at 02:55:00 was
   still `Running` and was most likely stopped before it connected (each run's connection appeared about a minute
   after its start), so the last real connection was about 02:51 PM. **The database paused at 03:06:04 PM**, about
   15 minutes later (inferred from the H1 timing, not measured directly).
2. **Fix (PR #20, merged 03:28:53 PM):**
   - Removed the job from `container-apps.bicep`, so no future deploy recreates it.
   - Kept the developer's goal, a warm API, with the platform setting instead: **`minReplicas: 1`**. The probes use
     `/healthz`, so a running replica opens no SQL connections.
   - Added **"Guard - nothing in infra calls /readyz"** to the required *Lint and build* job: it fails any PR with a
     string in `infra/` ending in `/readyz'` (a probe path or a URL). The design rule is now enforced, not just
     commented.

## Verification

| Time (EST) | Event |
|---|---|
| 01:50:57 PM | Baseline: last database use (session deploy smoke tests) |
| **02:07:58 PM** | Baseline: **Paused after 17 min idle** |
| 02:09:08 PM | PR #19 merged (keep-warm job) |
| 02:15:00 PM | First keep-warm execution |
| 02:15:51 PM | Deploy's idempotency check **failed** on `job-lark-keepwarm: value (Modify)` (below) |
| 02:19–02:50 PM | Database **Online** the whole time, 34.5 min past the last other call |
| 02:53 PM | Diagnosis: H1 and H2 confirmed |
| 02:55:21 PM | **Mitigation:** job deleted |
| 03:06:04 PM | Database **Paused** |
| 03:28:53 PM | PR #20 merged (fix + guard); the guard ran: `No /readyz calls in infra/` |
| 03:33:23 PM | Fix deploy smoke tests (last SQL use: 3 connections, `/readyz` + 2 lookups) |
| 03:33:43 PM | Idempotency **passed** |
| 03:48:49 PM | Database **Pausing** |
| **03:49:51 PM** | **Paused after 16.5 min idle, with the API up the whole time** (16 of 16 minutes with a replica; no SQL connections after the smoke tests) |

- `minReplicas 1 / maxReplicas 1` on the API; no `job-lark-keepwarm` in `rg-lark-app`.
- Free allowance at the end: **80,050** vCore-seconds (03:45 PM slot), from 82,591 when this session's database use
  began (01:50 PM).

## Things that tripped me up (and are now in the runbook)

- **The PR's what-if failed with `DeploymentActive`** because I ran it while a deploy was in progress. What-if
  evaluates the template's modules as nested deployments with the same names (`lark-container-apps`), and ARM won't
  overwrite an active one. A re-run after the deploy passed. Don't run PR validation during a deploy.
- **`az monitor metrics list` with only `--start-time` reads one hour**, because `--offset` defaults to 1 hour. My
  first query read 01:00–02:00 AM and found no data. Always pass both `--start-time` and `--end-time`.
- **My first burn-rate figure was wrong** (1,018/h, 3.3 days): it divided by a span that included paused time. The
  H3 figure replaces it.
- **The diagnosis tables printed times 5 hours late**: a `DateTime` that PowerShell had already converted was
  parsed again. The minute alignment was unaffected; later blocks convert once.
- **The keep-warm job's `KEEPWARM_URL` failed the idempotency check.** Its value is built from the API's FQDN, which
  what-if can't resolve, and `whatif-drift.jq` only drops values that *start with* `[reference(`. I didn't confirm the
  exact shape because the fix removed the job, but it's the same blind spot as INC-008 in a different form.

## What I learned

- **Health checks that touch dependencies have a cost.** `/readyz` is the right check for a deploy or a person;
  called on a schedule, it's a load generator. Liveness, readiness probes and keep-warm calls belong on `/healthz`.
- **On a free or serverless tier, "idle" is something you have to protect.** The failure mode wasn't an error, it
  was a budget quietly draining toward a month-long lockout.
- **A design rule in a comment isn't a control.** The guard turns it into one, at the cheapest point: the PR.
- **Mitigate first, then fix in code.** Deleting the job stopped the drain in minutes; the PR stopped it coming
  back. And with Incremental deployments, removing something from the template doesn't remove it from Azure.
- **Prefer the platform feature to a workaround.** `minReplicas: 1` does what the job was trying to do, with no
  schedule, no extra container and no dependency call.

## Prevention

| Option | Decision |
|---|---|
| Lint guard: no `/readyz` in `infra/` | **Done** (PR #20, in the required *Lint and build* check) |
| Keep the API warm with `minReplicas: 1` instead of a job | **Done.** Trade-off: one replica runs for the whole session instead of scaling to zero. The stack is torn down after every session, so the cost stays within the Container Apps free grant; an always-on production app would weigh this against cold starts. |
| Alert on burn rate, not just the 10,000 floor | **Proposed, not built.** For example, alert when `free_amount_consumed` rises by more than ~3,000 in 2 hours, or when the database has been Online for more than 2 hours. The current alert gives about 7 hours of warning at this incident's rate. |
| Deploy in Complete mode so removed resources are deleted | **Considered, not adopted.** Complete mode would also delete anything created outside the template in `rg-lark-app` (by design that's nothing, but the blast radius is large). The teardown already empties the group every session; an explicit delete during mitigation was the right tool here. |
| Make the idempotency filter handle any unresolved expression | **Deferred to M9** with the INC-008 item: the fix is to compare against resolved expected values, not to widen the string match. |
