# INC-009: Azure Policy denied a pull request's change, but nothing stopped the merge

| | |
|---|---|
| **Date** | 11-22-2026, 12:34 PM–12:50 PM EST |
| **Milestone** | M8 (operational incidents) |
| **Type** | Deliberate M8 incident: I opened a "tag cleanup" PR that renamed the `costCenter` tag key to `cost-center`, as a well-meant convention change, then worked it as the platform owner |
| **Impact** | **None in Azure.** Nothing was deployed, and no live resource changed. The near miss: the PR showed "Able to merge" with a failing check, so a merge would have put a change on `main` that fails every deploy. |
| **Status** | Resolved: PR #16 closed without merging; validate made a **required** check on `main` (ruleset), proven by PR #16 showing blocked |

## Symptoms

[`m8-11`](../evidence/m8-11-inc009-setup.txt), [`m8-12`](../evidence/m8-12-inc009-pr-whatif-denied.txt)

The PR changed one line in `infra/app/main.bicepparam`:

```diff
-  costCenter: 'CC-LARK-01'
+  'cost-center': 'CC-LARK-01'
```

The `validate` run on PR #16:

| Job | Result | Why |
|---|---|---|
| Lint and build | ✅ success | The change is valid Bicep (`az bicep build-params` exit code 0). Lint checks syntax, not policy. |
| **What-if (app stack)** | ❌ **failure** | `RequestDisallowedByPolicy` on 9 resources |
| Guardrail | ✅ success | gh-lark-plan was still refused `deployments/write` |

```
ERROR: InvalidTemplateDeployment - The template deployment failed with multiple errors.
RequestDisallowedByPolicy - Resource 'pe-lark-sql' was disallowed by policy. Reasons: 'Every Larkspur resource needs a costCenter tag so its cost can be allocated.'
```

Also denied: `pe-lark-kv`, `ca-lark-tracking-api`, `cae-lark`, `nsg-lark-aca`, `nsg-lark-pe`, `vnet-lark`, and
`link-vnet-lark` twice (once per private DNS zone, in `rg-lark-data`).

**And the PR page said "Able to merge… Some non-required checks."** The policy did its job; the repository didn't.

## Investigation

| Question | Check | Result |
|---|---|---|
| Which policy? | The error's reason text; the assignments on `rg-lark-app` | `lark-require-costcenter` (built-in "Require a tag on resources", Deny). The reason is the `nonComplianceMessages` text I wrote in M1, word for word. |
| Does the PR what-if really evaluate policy? | I didn't know beforehand. Microsoft documents that what-if runs preflight, but the preflight page doesn't list Azure Policy among its checks. | **Yes, measured.** The plan identity's what-if (`--validation-level ProviderNoRbac`, read-only role) was denied by preflight. |
| Did anything get deployed or changed? | Deployment history; the live tag | No deployment named `pr-16` exists. `ca-lark-tracking-api` still has `costCenter`. |
| Is there an audit trail? | Activity log for both resource groups | **Yes, after a delay** (below): `deployments/validate/action` Failed at 12:36:35 PM, then 17 `Microsoft.Authorization/policies/deny/action` events (13 in `rg-lark-app`, 4 in `rg-lark-data`), all by **gh-lark-plan**. |
| Could the PR be merged anyway? | The PR page; the repository's rules | **Yes.** `main` had no ruleset or branch protection, so validate was advisory. |

**Two things that could have misled me:**

- **The first activity log query returned 0 deny events.** It ran about 1.5 minutes after the denials. Two minutes
  later the same query returned all 17. Activity log data arrives with a delay, so an empty result right after an
  event isn't evidence that it didn't happen.
- **Preflight didn't evaluate every resource.** The three Container Apps jobs and the 5xx alert rule carry the same
  tags and aren't in the denial list. Microsoft notes preflight validation "may be incomplete when resources depend
  on values that are not yet available": the alert module takes `containerApps.outputs.apiName`, which fits. I
  haven't confirmed why the jobs were skipped. Either way, preflight is a strong check but not a complete one.

I also noticed each resource was denied **twice** (except `ca-lark-tracking-api`, once). That's consistent with one
evaluation for the validate call and one for the what-if, but I haven't confirmed it.

## Root cause

Two separate things, and only one of them was a bug:

1. **The change:** renaming the tag key removed `costCenter` from every resource in the stack. The Deny policy
   exists to stop exactly that, and it did, at the earliest possible point: the PR.
2. **The gap (the real root cause):** the `validate` checks weren't **required** on `main`. A failing what-if was
   shown, but it didn't block anything. If the PR had been merged, the next session's deploy would have failed in
   its own what-if, after I'd approved it, and `main` would have stayed broken until someone reverted it.

The `paths:` filter on `validate.yml` was a hidden second gap. GitHub documents that a required workflow skipped by
path filtering stays "Pending" and blocks the PR. So I couldn't simply require the checks: every docs-only PR
would have been stuck.

## Remediation

| Time (EST) | Action |
|---|---|
| 12:43:53 PM | PR #17 merged: `validate.yml` runs on **every** PR (the `paths:` filter removed, with a comment explaining why). All 3 checks passed on that PR. |
| ~12:49 PM | Ruleset `main: required checks` created and **Active**, bypass list empty |
| 12:50 PM | PR #16 confirmed **blocked** (`mergeable=true`, `mergeable_state=blocked`): no conflicts, stopped only by the failed What-if check |
| 12:50:26 PM | PR #16 closed without merging; branch deleted |

The ruleset on `main`:

| Rule | Setting | Why |
|---|---|---|
| Require status checks to pass | `Lint and build`, `What-if (app stack)`, `Guardrail - plan identity cannot deploy`, each from GitHub Actions | All three, not just What-if: What-if and Guardrail `need` lint, and GitHub skips jobs whose dependency failed. **A skipped check counts as passing**, so requiring only What-if would let a lint failure through. |
| Require a pull request before merging | 0 approvals | Blocks direct pushes to `main`. 0 because I can't approve my own PR. |
| Block force pushes, Restrict deletions | On | Protects history |
| Require branches to be up to date | Off | One person, low PR volume: not worth a rebase before every merge |
| Bypass list | Empty | The rules apply to me too |

## Verification

- PR #16, with its failed What-if, went from "Able to merge" to **blocked** as soon as the ruleset was active.
- This write-up's own PR is the first one merged under the new rule. It can't merge until all three checks pass,
  and it proves docs-only PRs aren't stuck now that the `paths:` filter is gone.

## What I learned

- **Shift-left worked: policy caught the mistake at the PR, before approval and before any deployment.** A Deny
  policy is checked during preflight, so a read-only plan identity's what-if is enough to surface it.
- **A check that doesn't block is a suggestion.** The PR stayed mergeable with a red check. Guardrails only count
  if they're enforced.
- **Required checks interact with workflow design.** Path filters leave required checks Pending forever, and
  skipped jobs count as passing. Both had to be handled before requiring anything.
- **Write the policy's non-compliance message for the person who'll read it.** The PR error explained *why* in my
  own words, so the developer doesn't need to look up the policy.
- **Lint and policy are different layers.** The change was valid Bicep; it was invalid for this organization.
- **Measure, don't assume.** I didn't know whether the PR what-if would evaluate policy, and the activity log
  looked empty at first. Both questions were settled by evidence, not by guessing.

## Prevention

| Option | Decision |
|---|---|
| Make validate a required check on `main` | **Done** (ruleset, above) |
| Run validate on every PR | **Done** (PR #17) |
| Also check policy for the data stack in PRs | **Proposed, not built.** The PR what-if covers only the app stack. The data stack is deployed by me as admin behind its gate (INC-007), so a data-stack policy violation would only show up then. It's a candidate for the M9 data-stack gate script. |
| Show the what-if error in the PR's run summary | **Proposed, not built.** The error goes to stderr, so the run summary was empty and I had to open the job log. Redirecting `2>&1` into the summary would put the reason on the PR page. |
| A lint-time check that the `tags` object contains `costCenter` | **Considered, not adopted.** The policy already catches it in the PR, and duplicating the rule in two places means two places to update. |
