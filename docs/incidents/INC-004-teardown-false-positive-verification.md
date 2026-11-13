# INC-004: Teardown reported a billing group as "gone" without being able to see it

| | |
|---|---|
| **Date** | 11-13-2026, 10:58 AM–11:36 AM EST |
| **Milestone** | M5 (deployment pipeline) |
| **Impact** | None to cost (the group really was gone), but the pipeline's teardown printed a verification it couldn't have made. If the group had been left behind, its load balancer and public IPs would have kept billing while the log said they were gone |
| **Status** | Resolved: the check fails on any error; the deploy identity can read resource group metadata |

## Symptoms

The first `teardown` run from GitHub Actions deleted everything in `rg-lark-app`, then ended with:

```
verified       rg-lark-app is empty
ERROR: Operation returned an invalid status 'Forbidden'
ERROR: Operation returned an invalid status 'Forbidden'
verified       rg-lark-app-infra is gone
ERROR: Operation returned an invalid status 'Forbidden'
##[error]Process completed with exit code 1.
```

"Gone" was printed right after the check that should prove it was refused.

Evidence: [`m5-07-teardown-run1-forbidden.txt`](../evidence/m5-07-teardown-run1-forbidden.txt)

## Root cause

- `rg-lark-app-infra` is created and deleted by Container Apps with the environment. `gh-lark-deploy` has roles on
  `rg-lark-app` and `rg-lark-data` only, so it can't read that group, and `az group exists` was refused.
- When `az group exists` is refused, it prints nothing. My script treated anything other than `true` as "gone".
- The script had only ever run under my admin account, where the check always worked, so the bug never showed.

A refused check is not a negative result. My script turned "I can't tell" into "it's gone".

## Options considered

| Option | Decision |
|---|---|
| Grant a role on `rg-lark-app-infra` | Not possible: the group doesn't exist between sessions, and Azure recreates it each time |
| Skip the check in the pipeline and trust Azure to delete the group | Rejected: that group is exactly what keeps billing if something goes wrong |
| Built-in Reader on the subscription | Rejected: far more read access than the check needs, across my other projects |
| **Custom role with only `Microsoft.Resources/subscriptions/resourceGroups/read` on the subscription** | Chosen: it shows resource group names, locations and tags, and nothing inside any group |

## Remediation

- `scripts/Remove-LarkAppResources.ps1`: the managed-group check now throws if `az group exists` fails or returns
  anything other than `true`/`false`, and throws if the group still exists after 10 minutes. It prints "gone" only
  when Azure answers `false`.
- `.github/workflows/teardown.yml`: the independent re-check also fails on any error, and fails if
  `rg-lark-app-infra` still exists.
- New role `identity/larkspur-group-reader.role.json`, created and assigned to `gh-lark-deploy` on the subscription
  by `Initialize-LarkPipeline.ps1`. It's the only subscription-scope assignment in the design, and the script's
  verify step labels it as such.

## Verification

| Check | Result |
|---|---|
| Real state right after the incident (as admin) | `rg-lark-app`: 0 resources; `rg-lark-app-infra` exists: `false`; VNet links: 0 |
| Role and assignment | `created Larkspur Group Reader`; `gh-lark-deploy  Larkspur Group Reader @ subscription (group metadata only)` ([`m5-08`](../evidence/m5-08-group-reader.txt)) |
| Teardown run 2 as `gh-lark-deploy` | Success, no `Forbidden`: `verified rg-lark-app-infra is gone` from a real `false` ([`m5-09`](../evidence/m5-09-teardown-run2-verified.txt)) |

## Prevention

- A verification step must fail when it can't verify. "Unknown" is a failure, never a pass.
- A script that will run under automation gets tested under the automation identity, not only under my admin account.
