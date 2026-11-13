# INC-003: First pipeline deploy failed on a linked-scope permission and a pending delete

| | |
|---|---|
| **Date** | 11-13-2026, 10:09 AM–10:56 AM EST |
| **Milestone** | M5 (deployment pipeline) |
| **Impact** | My first `deploy` run left a partial stack (network, private endpoints, environment, jobs) with no API and no logging; it billed at about $0.06/hr until the fix was deployed |
| **Status** | Resolved: permission added to the custom role, one targeted retry, full error messages in the pipeline |

## Symptoms

The first `deploy` run failed in the deploy step. The pipeline's failed-operations step reported two failures inside
`lark-container-apps`:

```
ca-lark-tracking-api: FailedIdentityOperation ... Status: 'Conflict' ... "Request specified that resource
'.../containerApps/ca-lark-tracking-api' is new, but resource already exists. This may be due to a pending delete
operation, try again later."

diag-to-log-lark: LinkedAuthorizationFailed: The client '<guid>' ... has permission to perform action
'Microsoft.Insights/diagnosticSettings/write' on scope '.../managedEnvironments/cae-lark/...'; however, it does not
have permission to perform action(s) 'Microsoft.OperationalInsights/workspaces/sharedKeys/action' on the linked
scope(s) '.../resourceGroups/rg-lark-data/providers/Microsoft.OperationalInsights/workspaces/log-lark'
```

The pipeline cut both messages off at 400 characters, which hid the important half, so I pulled the full text with
`az deployment operation group list` as admin.

Evidence: [`m5-03-deploy-run1-failed.txt`](../evidence/m5-03-deploy-run1-failed.txt)

## Root cause

There were two separate causes.

**1. Linked-scope authorization (a gap in my role design).** In M5 I moved Container Apps logging to an Azure Monitor
diagnostic setting so the workspace key would no longer pass through the template. Creating a diagnostic setting is
authorized twice: on the resource the setting is attached to (`cae-lark`, where `gh-lark-deploy` is Contributor),
and on the **destination** it points to (`log-lark` in `rg-lark-data`). For a Log Analytics destination, Azure
requires `Microsoft.OperationalInsights/workspaces/sharedKeys/action` on the workspace. My Data-Tier Integrator role
had `*/read` but not that action. The key itself still never appears in the template or the deployment history;
the deploy identity just has to be allowed to use it.

**2. A pending delete (transient).** I had deleted `ca-lark-tracking-api` earlier that morning. Azure's
managed-identity service was still cleaning up the identity record for an app with that exact name, so it refused to
create a "new" one. The migration job, with a different name, attached its identity without any problem.

## Remediation

- Added `Microsoft.OperationalInsights/workspaces/sharedKeys/action` to
  `identity/larkspur-data-tier-integrator.role.json`. The role is still assignable only in `rg-lark-data` and has no
  data actions.
- `Initialize-LarkPipeline.ps1` used to only create missing roles, so a change to a role file would never have reached
  Azure. It now syncs each custom role from its JSON file. My first attempt at that failed:
  `az role definition update` needs the format `az role definition list` returns (`name` = GUID, `roleName` = display
  name), not the create format. The script now updates the deployed definition with the file's permissions.
- `deploy.yml` now prints failed-operation messages up to 1,500 characters, and retries the deployment **once**,
  after 2 minutes, **only** when the failure says "pending delete operation". Every other failure still stops the run.

Files: `identity/larkspur-data-tier-integrator.role.json`, `scripts/Initialize-LarkPipeline.ps1`,
`.github/workflows/deploy.yml`, `infra/app/modules/container-apps.bicep` (corrected comment)

## Verification

| Check | Result |
|---|---|
| Role synced in Azure | `updated Larkspur Data-Tier Integrator (added: Microsoft.OperationalInsights/workspaces/sharedKeys/action)` ([`m5-04`](../evidence/m5-04-role-sync.txt)) |
| Deploy run 2 | Deploy **succeeded on the first attempt**; the pending delete had cleared on its own, so the retry wasn't needed. Migration and all 5 smoke tests passed ([`m5-05`](../evidence/m5-05-deploy-run2-drift.txt)) |
| Deploy run 2, idempotency | Failed on the new diagnostic setting: a separate finding, fixed in PR #3 (below) |
| Deploy run 3 | Every step passed, including **Idempotency: PASS** ([`m5-06`](../evidence/m5-06-deploy-run3-pass.txt)) |

**Follow-up finding (same session):** after run 2 succeeded, the idempotency check found 4 real differences on
`diag-to-log-lark`. Azure adds the `audit` log group and `AllMetrics` as disabled entries with a zero retention policy,
and stores `logAnalyticsDestinationType` as null. I now declare the setting exactly as Azure stores it, so the template
matches reality instead of the filter hiding it.

## Prevention

- When a resource **points at** something in another scope (a diagnostic setting at a workspace, an endpoint at a
  server, an identity assigned to an app), I check the permissions on the target as well as on the resource.
- Pipeline error output has to include the whole message. A truncated root cause cost me a round trip.
- Retries stay targeted at one known transient error. A blanket retry would have hidden the permission bug.
