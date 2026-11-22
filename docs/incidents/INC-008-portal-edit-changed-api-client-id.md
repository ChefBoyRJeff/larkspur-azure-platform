# INC-008: A portal edit pointed the API at the wrong managed identity

| | |
|---|---|
| **Date** | 11-22-2026, 11:59 AM–12:23 PM EST |
| **Milestone** | M8 (operational incidents) |
| **Type** | Deliberate M8 incident: I edited the container app in the portal and set `AZURE_CLIENT_ID` to the migrator identity's client ID, as a "quick config fix" mistake, then worked it as on-call |
| **Impact** | Every shipment lookup returned **HTTP 500** and `/readyz` returned 503, for at most **23 min 37 s** (the bad revision going live to the first verified good check). `/healthz` stayed 200, so the app looked alive. |
| **Status** | Resolved by redeploying the app stack through the pipeline; verified by smoke tests, the revision history and 10 of 10 lookups returning 200 |

## Symptoms

[`m8-08`](../evidence/m8-08-inc008-symptoms.txt)

- `/shipments/LRK100001`: **HTTP 500 x 10**, starting at 12:00:39 PM.
- `/readyz`: **HTTP 503**, with SQL and Key Vault failing the same way:
  `CredentialUnavailableError: App Service managed identity configuration not found in environment. invalid_scope`
- `/healthz`: **HTTP 200**. The process was up; only calls that need a token failed.
- DNS was healthy: SQL still resolved to `10.60.1.4`.
- The **5xx alert email arrived at 12:08 PM**, about 7–8 minutes after the first failures, which matches the timing I measured in INC-006.

Before reading symptoms I confirmed the change was in place, the habit from INC-006. The app's `AZURE_CLIENT_ID`
hashed to `02355a18cf2e` (id-lark-migrator) instead of `e9c550f2a959` (id-lark-tracking-api, baseline
[`m8-01`](../evidence/m8-01-baseline.txt)). Values were compared by SHA-256 and never printed.

## Investigation

[`m8-09`](../evidence/m8-09-inc008-diagnosis.txt)

| Hypothesis | Check | Result |
|---|---|---|
| H1: network or DNS | `/readyz` DNS check and the error type | Ruled out: SQL resolved to `10.60.1.4`, and the failure came before any connection was attempted. |
| H2: authorization (INC-007 again?) | The API identity's role assignments; the error type | Ruled out: Key Vault Secrets User is in place, and there was **no 403**. INC-007's error named the caller; this one never got a token at all. |
| H3: the identity was detached from the app | The identities assigned to `ca-lark-tracking-api` | Ruled out: `id-lark-tracking-api` is still the only one attached. |
| H4: the app asks for an identity it doesn't have | `AZURE_CLIENT_ID` vs the attached identity | **Confirmed:** the app asked for id-lark-migrator's token, but that identity isn't attached to the app, so the platform couldn't issue one. |
| What changed | Revision diff, using `revision list --all` (inactive revisions are hidden without it) | `--7xecdm7` → `--0000001`: **only** `AZURE_CLIENT_ID` changed (API identity → migrator); same image `15df5aa`. |
| Who and when | Activity log, `Microsoft.App/containerApps/write` | A **user** write Started at **11:59:08 AM**; revision `--0000001` was created at 11:59:17 AM and took 100% of traffic. |

## Root cause

A portal edit ("Edit and deploy" on the container) changed the `AZURE_CLIENT_ID` environment variable to the
client ID of `id-lark-migrator`. The API reads that variable and passes it to
`ManagedIdentityCredential(client_id=...)` (`app/larkspur/config.py`, `main.py`), which decides **which** user-assigned
identity to request a token for. The migrator identity is assigned to the migration job, not to the API, so the
platform's identity endpoint had nothing to give, and the SDK failed with `CredentialUnavailableError` before
calling SQL or Key Vault. (The message says "App Service" because Container Apps uses the same identity endpoint
protocol as App Service.)

The app runs in **single revision mode**, so the portal edit created a new revision and moved all traffic to it at
once. Nothing stood between the edit and production.

**This is authentication, not authorization.** No token was issued, so no service ever got the chance to say yes
or no. It's the mirror image of INC-007:

| | INC-007 | INC-008 |
|---|---|---|
| Error | `Forbidden`, names the caller's `oid` and `appid` | `CredentialUnavailableError`, no token |
| Question it answers | "You can't do that" | "Who are you?" |
| Fix lives in | Role assignments (data stack) | App configuration (app stack) |

## Remediation

The correct value is defined in code: the app stack sets `AZURE_CLIENT_ID` from
`reference(id-lark-tracking-api).clientId`. So the fix was a normal pipeline deploy, not another portal edit. That
way the fix goes through the same approval and smoke tests as every other change, and the repo stays the source of truth.

Deploy run 45048644241 was created at 12:17:57 PM and approved on the `production` environment. The deployment
wrote the container app at 12:19:37 PM (caller `gh-lark-deploy`), created revision `--0000002` at 12:19:43 PM, and
the smoke tests passed at 12:22:55 PM.

**The pipeline's own what-if showed the fix, and I still couldn't have spotted the drift from it.** Its pre-deploy
what-if listed four rows of exactly the same shape:

| Resource | Row | Real? |
|---|---|---|
| `ca-lark-tracking-api` env[4] `AZURE_CLIENT_ID` | `"<guid>" => [reference(id-lark-tracking-api).clientId]` | **Yes: the drift being repaired** |
| `job-lark-drill` env[4] | `"<guid>" => [reference(...).clientId]` | Noise |
| `job-lark-migrate` env[4] | `"<guid>" => [reference(id-lark-migrator).clientId]` | Noise |
| `job-lark-migrate` env[6] | `"<guid>" => [reference(id-lark-tracking-api).clientId]` | Noise |

The pipeline masks the "before" GUID, and what-if can't resolve `reference()` until deployment, so it always
reports these rows as a Modify. `scripts/whatif-drift.jq` drops every leaf whose "after" starts with `[reference(`,
so all four disappear together. A local what-if with the raw JSON did show the real "before" value
(the migrator's client ID), so the information exists; the display and the filter both hide it.

## Verification

[`m8-10`](../evidence/m8-10-inc008-fix.txt)

| Time (EST) | Event |
|---|---|
| 11:32:54 AM | Session deploy by the pipeline: revision `--7xecdm7`, API identity |
| **11:59:08 AM** | Portal edit: `containerApps/write` by a user |
| 11:59:17 AM | Revision `--0000001` created (migrator client ID) and given 100% of traffic |
| 12:00:39 PM | First checks: `/shipments` HTTP 500 x 10, `/readyz` 503 |
| 12:02:20 PM | Diagnosis started |
| 12:08 PM | 5xx alert email received |
| 12:14:47 PM | Revision diff: `AZURE_CLIENT_ID` was the only change |
| 12:17:57 PM | Fix: deploy run 45048644241 created and approved |
| 12:19:43 PM | Revision `--0000002` created by the pipeline (API client ID) |
| **12:22:54 PM** | Smoke tests: `/readyz` 200, SQL at `10.60.1.4`, Key Vault ok; lookups 200/404/400 as expected |
| 12:23:14 PM | Idempotency check passed |
| 12:27:25 PM | My own check: `/readyz` 200, **10 of 10** parallel lookups 200 |

- `AZURE_CLIENT_ID` hashes to `e9c550f2a959` again. Exactly one revision is active (`--0000002`, 100% traffic, API
  identity); `--0000001` is inactive with 0% traffic.
- **Impact window:** at most 23 min 37 s, from the bad revision (11:59:17 AM) to the first verified good check
  (12:22:54 PM). The service probably recovered a few minutes earlier, once `--0000002` took traffic, but nothing
  was checking it between 12:19 and 12:22, so I report the upper bound.

**Two things I noticed in the evidence:**

- **The activity log query lies by omission.** My first query showed only the pipeline's writes, because
  `az monitor activity-log list` returns the newest **50** events unless you pass `--max-events`. The fix deploy
  wrote enough events to push the 11:59 AM portal write out. With `--max-events 2000` it returned 148 events and
  the user write was there.
- **The portal write logged `Started` and `Accepted`, but no `Succeeded`**, while both pipeline writes logged all
  three. The write clearly took effect (revision `--0000001` served traffic). I haven't found why yet, so I record it
  as an observation, not a finding. The lesson: don't treat a missing `Succeeded` event as proof a change failed.

## What I learned

- **No token means authentication, and a 403 that names you means authorization.** INC-007 and INC-008 broke the same
  two dependencies with different errors, and the error type alone pointed at the right layer within minutes.
- **`/healthz` 200 doesn't mean healthy.** Liveness only proves the process is running; `/readyz` exercises the
  identity, SQL and Key Vault and is the check that matters.
- **A portal edit in single revision mode is a production deploy with no review.** It skipped the PR, the
  approval and the smoke tests, and took effect in seconds.
- **The what-if noise I documented earlier hides real drift.** I accepted `[reference()]` rows as noise because
  they appear on every run. That was true, but it also meant a real change of the same shape was invisible.
- **My idempotency gate can't catch this class of drift.** It runs after the deploy has already rewritten the value,
  so it only proves the deploy converged. Nothing checks for drift *between* deploys.

## Prevention

| Option | Decision |
|---|---|
| Least privilege: only admins can write the app | **Already the design.** `lark-dev` and `lark-ops` are Reader; only my Owner account and `gh-lark-deploy` can change the container app. This incident needed an Owner, which is the right bar. |
| Scheduled drift check: compare each app's and job's `AZURE_CLIENT_ID` with the client ID of the identity it should use | **Proposed, not built.** It's the check this incident needed, and it's cheap: a few reads every hour while the stack is up. It belongs with the M9 scripting work. |
| Make the what-if filter smarter | **Proposed, not built.** Instead of dropping every `[reference(` leaf, resolve the expected client IDs before the what-if and keep any row whose "before" isn't the expected value. The raw what-if JSON has the "before" value; the pipeline only masks it for display. |
| Multiple revision mode, so a new revision gets 0% traffic until promoted | **Considered, not adopted.** It would have contained this incident, but the pipeline would then need a promote-and-rollback step. It's worth it for a real production app, but too much extra machinery for this lab today. |
| Alert on `Microsoft.App/containerApps/write` by a **user** (not the pipeline) | **Proposed, not built.** In this design the pipeline is the only expected writer, so a user write is always worth a look. Pairs with the role-assignment delete alert proposed in INC-007. |
| Outside-in check on `/readyz` | **Proposed, not built** (see INC-006 and INC-007). The 5xx alert worked here only because there was traffic; a `/readyz` probe would catch this even with no users. |
