# Larkspur platform runbook

How I start, check, troubleshoot and end a session, written from what actually happened in M5–M8. Times are EST;
Azure logs and metrics are UTC.

**Before anything:** PowerShell 7, Azure CLI signed in as the subscription Owner (`az login`, then `az account show`),
and the repository cloned with `main` pulled. Nothing here needs a secret pasted anywhere.

## Rules I follow

1. **Fix through the normal path.** App stack → the `deploy` workflow; data stack → admin deploy behind its what-if
   gate; code → a pull request. A portal or CLI change is only for **mitigation**, and it gets written down and then
   replaced by the code fix (INC-008, INC-010).
2. **Confirm the change or break is really in place before reading symptoms** (INC-006).
3. **Close an incident on a verified check, never on an alert resolving** (INC-006).
4. **Don't open or re-run pull requests while a deploy is running** (the PR's what-if fails with `DeploymentActive`).
5. **End every session with the teardown**, and trust only its "verified" lines.

## Start a session

1. GitHub → **Actions** → **deploy** → **Run workflow** (branch `main`, `image_tag` empty) → **Run workflow**.
2. Approve: open the run → **Review deployments** → tick **production** → **Approve and deploy**.
3. Wait about 21 minutes on a fresh stack (the Container Apps environment takes most of it), or about 5 minutes when
   the stack already exists.
4. Success = every step green, ending with **Smoke tests from the internet** (`/readyz` 200 with SQL at `10.60.1.x`,
   lookups 200/404/400) and **Idempotency: PASS**.

If you merged a change under `app/`, wait for **app-image** to finish first; the deploy's image check stops the run
if the image isn't published yet (M7).

## Quick health check

```powershell
$fqdn = az containerapp show -g rg-lark-app -n ca-lark-tracking-api --query properties.configuration.ingress.fqdn -o tsv
Invoke-RestMethod "https://$fqdn/readyz"            # ready=true; sql_dns 10.60.1.x; sql ok; key_vault ok
Invoke-RestMethod "https://$fqdn/shipments/LRK100001"
./scripts/Test-LarkPrivateDns.ps1                     # what the app resolves from inside the VNet (public IPs masked)
```

The first SQL call after the database has been paused can take about a minute while it resumes; that is normal on
the free tier.

## End a session

1. GitHub → **Actions** → **teardown** → **Run workflow** → approve on **production**.
2. About 30 minutes. Success = the log lines `verified rg-lark-app is empty` and `verified rg-lark-app-infra is gone`.
3. Locally, `./scripts/Remove-LarkAppResources.ps1 -WhatIf` previews the same deletion; without `-WhatIf` it runs it.

`rg-lark-data` stays. Check the database paused about 15–17 minutes after the last use:
`az sql db show -g rg-lark-data -s <server> -n sqldb-lark-tracking --query status -o tsv` → `Paused`.

## Change the data stack (admin)

```powershell
az deployment group what-if -g rg-lark-data -f infra/data/main.bicep -p infra/data/main.local.bicepparam
az deployment group create  -g rg-lark-data -f infra/data/main.bicep -p infra/data/main.local.bicepparam
```

Deploy only if the what-if shows the change you expect plus documented noise:

| Noise | Why it's safe |
|---|---|
| Role assignment `principalId` / `principalType` | what-if can't resolve the identity reference |
| Action group `emailReceivers` | `@secure()` value; compare the address by SHA-256, never print it |
| Workbook `properties.serializedData` Modify | what-if reads workbooks without their content, so "before" is empty; proven by hashing the normalized template (INC-007) |

Anything else: stop and explain it before deploying.

## Triage by symptom

| Symptom | First check | Likely cause | Fix | Reference |
|---|---|---|---|---|
| `/readyz` 503, `sql_dns` shows a **public** address | `./scripts/Test-LarkPrivateDns.ps1` | SQL private DNS zone lost its VNet link | Redeploy the app stack | INC-006 |
| `/readyz` 503, Key Vault **403 `Forbidden`** naming the API's `oid` | `az role assignment list --assignee <API identity principal ID> --all` | The identity lost Key Vault Secrets User (authorization) | Data-stack deploy behind the gate | INC-007 |
| `/readyz` 503, **`CredentialUnavailableError`**, no 403; `/healthz` 200 | `az containerapp revision list -g rg-lark-app -n ca-lark-tracking-api --all`, compare `AZURE_CLIENT_ID` by hash | The app asks for an identity it doesn't have (authentication) | Redeploy the app stack | INC-008 |
| Lookups 500 after a release, `/readyz` fine | The deploy's smoke tests; recent merges under `app/` | A bad release | Deploy with `image_tag` = the last good image SHA, then revert on `main` | M7 Drill C |
| `/readyz` 503 `SecretNotFound` | `./scripts/Start-LarkDrill.ps1 -DrillArgs 'secret-check'` (Key Vault refuses my PC: it only answers inside the VNet) | Secret deleted (soft delete keeps it 7 days) | `./scripts/Start-LarkDrill.ps1 -DrillArgs 'secret-recover'` | M7 Drill B |
| Wrong or missing data | `./scripts/Start-LarkDrill.ps1 -DrillArgs 'snapshot'` | Bad write or delete | Point-in-time restore to a copy, `compare --target <copy>`, then `repair --source <copy> --confirm`; delete the copy (it's paid) | M7 Drill A |
| PR what-if fails `RequestDisallowedByPolicy` | The `Reasons:` text in the error | The change breaks an Azure Policy (tag, location) | Fix the code; the merge is blocked until the check passes | INC-009 |
| PR what-if fails `DeploymentActive` | Actions: is a deploy running? | Overlap with a deploy | Re-run the failed job after the deploy | INC-010 |
| Database **Online** for more than 30 minutes with no users | SQL `connection_successful` per minute vs job schedules | Something is calling SQL on a schedule | Stop the caller (mitigation), then fix it in code | INC-010 |
| `alert-lark-sql-free-amount` fired | `free_amount_remaining` trend | Database not pausing | As above; at the limit the database locks until the 1st | INC-010 |
| Deploy fails "pending delete operation" | Deploy log | Azure still cleaning up the last teardown | The deploy retries once by itself; otherwise wait and re-run | INC-003 |
| Teardown can't confirm `rg-lark-app-infra` is gone | Teardown log | Permission or timing | Never treat "can't check" as "gone"; re-run teardown | INC-004 |
| 5xx alert resolved but the app is still failing | `/readyz` | The alert counts failures; no traffic looks healthy | Keep working the incident; close it on a verified check | INC-006 |

## Commands I always get wrong (unless I follow these)

| Task | Do this | Because |
|---|---|---|
| Activity log | `az monitor activity-log list -g <rg> --start-time <UTC> --max-events 2000` | The default returns only 50 events (INC-008); rows also arrive minutes late (INC-009) |
| Metrics | `az monitor metrics list ... --start-time <UTC> --end-time <UTC>` | With only a start time, `--offset` reads just one hour (INC-010) |
| Revisions | `az containerapp revision list ... --all` | Inactive revisions are hidden without it |
| Log Analytics from PowerShell | `az rest --method post --url https://api.loganalytics.io/v1/workspaces/<id>/query --body "@file.json"` | `az.cmd` breaks on `&` in a URL; a body file avoids it |
| Times from `ConvertFrom-Json` | Use the `DateTime` it returns; don't parse its string again | Re-parsing shifts it by the local offset (INC-010) |
| Removing a resource from Bicep | Also delete it in Azure | The pipeline deploys in Incremental mode, which never deletes |

## Where to look

- **Larkspur Operations workbook** (`rg-lark-data`): requests by status class, 5xx responses, app warnings and errors,
  and the SQL free-tier vCore-seconds remaining.
- **Alerts** to email: `alert-lark-api-5xx` (session), `alert-lark-sql-free-amount`, `alert-lark-data-resource-health`,
  and the $5 budget.
- **Logs:** `log-lark`, tables `ContainerAppConsoleLogs` and `ContainerAppHTTPLogs`.
- **History:** every incident in `docs/incidents/`, every command output in `docs/evidence/`.
