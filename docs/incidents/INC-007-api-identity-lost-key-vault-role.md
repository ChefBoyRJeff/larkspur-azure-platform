# INC-007: The API identity lost its Key Vault role

| | |
|---|---|
| **Date** | 11-22-2026, 11:40 AM–11:50 AM EST |
| **Milestone** | M8 (operational incidents) |
| **Type** | Deliberate M8 incident: I removed the role assignment in the portal, as a "permissions cleanup" mistake, then worked it as on-call |
| **Impact** | `/readyz` returned 503 for 9 min 38 s because the API couldn't read `carrier-api-key`. Shipment lookups were unaffected (they don't use the secret). |
| **Status** | Resolved by redeploying the data stack behind its what-if gate; verified by `/readyz` and a clean what-if |

## Symptoms

- `/readyz` → **HTTP 503**, with the Key Vault check failing:
  `(Forbidden) Caller is not authorized to perform action on resource. If role assignments, deny assignments or role
  definitions were changed recently, please observe propagation time. Caller: appid=<guid>;oid=<guid>;iss=https://sts.windows…`
- SQL and DNS checks stayed healthy, and `/shipments/LRK100001` → **HTTP 200**.
- No alert fired. The 5xx alert needs 5 failures in 15 minutes, and only my checks called `/readyz`.

Before reading symptoms I confirmed the change was in place (the lesson from INC-006): the identity had no role
assignments left. Evidence: [`m8-05`](../evidence/m8-05-inc007-symptoms.txt)

## Investigation

[`m8-06`](../evidence/m8-06-inc007-diagnosis.txt)

| Hypothesis | Check | Result |
|---|---|---|
| H1: the network path is blocked | Error type | Ruled out: the vault answered `Forbidden` and named the caller. A blocked path is `ForbiddenByConnection` or a timeout. |
| H2: authentication is broken | The `oid` and `appid` in the error vs `id-lark-tracking-api`, compared by SHA-256 | Ruled out: **both match**. The token was valid; Key Vault knew exactly who was calling. |
| H3: the secret is gone | Secret metadata through ARM (Owner can read metadata, never the value) | Ruled out: `carrier-api-key` exists and is enabled. A missing secret is a 404, not a 403. |
| H4: the vault moved off RBAC | `enableRbacAuthorization` | Ruled out: `True` |
| H5: no role grants the read | The identity's role assignments vs baseline [`m8-01`](../evidence/m8-01-baseline.txt); every assignment that applies to the vault | **Confirmed:** the identity had **none**. The vault's only data-plane role was Key Vault Secrets Officer for the migrator; my inherited Owner and User Access Administrator are control-plane roles and don't read secrets either. |
| Who and when | Activity log | `roleAssignments/delete` on the vault, **Succeeded 11:40:33 AM**, caller a user |

## Root cause

The `Key Vault Secrets User` assignment for `id-lark-tracking-api` on `kv-lark-…` was deleted. The vault uses Azure
RBAC, so with no role granting `Microsoft.KeyVault/vaults/secrets/getSecret/action`, every read was refused.

**This is authorization, not authentication.** The identity signed in successfully and the token was accepted; the
refusal was about what it was allowed to do. That's the distinction I check first in any access-denied case: a
token or sign-in error means "who are you?", a 403 that names the caller means "you can't do that".

## Remediation

The assignment is defined in `infra/data/modules/identities.bicep`, so I redeployed the data stack as admin, behind
the what-if gate.

**The gate stopped the first attempt** on a change I hadn't seen before: `Modify` on the Larkspur Operations
workbook's `properties.serializedData`. Instead of adding it to the noise list, I proved it
([`m8-07`](../evidence/m8-07-inc007-fix.txt)):

- What-if's "before" value for `serializedData` was **empty**. A workbook only returns its content when the request
  includes `canFetchContent=true`, and what-if doesn't send it.
- The deployed content, read with `canFetchContent=true`, and the template content built the way `workbook.bicep`
  builds it, had the **same normalized SHA-256** (`7e4a0a9d9c52`).
- So it's a what-if blind spot, like the `@secure` action group email: it will appear on every data-stack what-if.

With that proven, the gate passed: one Create (Key Vault Secrets User → `id-lark-tracking-api`), everything else
explained. The deployment recreated the **same** assignment name, because the name is a GUID computed from the
vault, the identity and the role.

## Verification

| Time (EST) | Event |
|---|---|
| 11:40:33 AM | Role assignment deleted (portal, a user) |
| 11:42:17 AM | First `/readyz` check: 503, `Forbidden` (the removal had taken effect within 1 min 44 s) |
| 11:43:38 AM | Root cause confirmed |
| 11:46:19 AM | First fix attempt: gate stopped on the workbook change; nothing deployed |
| 11:47:56 AM | Workbook proven unchanged; gate passed |
| 11:49:45 AM | Data-stack deploy Succeeded; the assignment is back |
| **11:50:11 AM** | `/readyz` → 200, `key_vault ok=True` (the grant had taken effect within 26 s of the deploy) |

- **Readiness impact:** 9 min 38 s (removal to the first passing check). **Customer impact:** none.
- After the fix, a second what-if showed **0** Create/Delete changes.
- Both role changes took effect faster than the up-to-10 minutes Microsoft allows for; I measured the upper bounds
  my 30-second checks could see, not the exact propagation time.

## What I learned

- **A 403 that names the caller is an authorization problem.** The fastest proof is comparing the caller IDs in the
  error with the identity you expect.
- **Owner isn't data-plane access.** Owner can manage the vault and read secret metadata, but reading a secret's
  value takes a data-plane role such as Key Vault Secrets User.
- **The what-if gate earned its keep.** It stopped on a change I didn't expect. The right response was to prove it,
  not to widen the allowlist.

## Prevention

| Option | Decision |
|---|---|
| Least privilege: only admins and the pipeline change role assignments | **Already the design.** Only Owner / User Access Administrator (me) can delete this assignment; `lark-ops` and `lark-dev` are Reader. |
| Drift repair from code | **In place.** The data-stack deploy recreates the assignment, and what-if names it. |
| Alert on `Microsoft.Authorization/roleAssignments/delete` in `rg-lark-data` | **Proposed, not built.** Role changes in the persistent data tier are rare (unlike DNS links, teardown never deletes them), so this alert wouldn't be noisy. It's the best next step. |
| A `CanNotDelete` lock on the vault | **Rejected:** it would block teardown deleting the Key Vault private endpoint's connection record, the same failure as INC-002. |
| Outside-in check on `/readyz` | **Proposed, not built** (see INC-006): no alert fired here because nothing called `/readyz` often enough. |
| Teach the gate about the workbook | **Recorded, not yet scripted:** the check (accept the workbook `Modify` only when its content hash matches the template) is in [`m8-07`](../evidence/m8-07-inc007-fix.txt). The data-stack gate is still a block I paste, not a script in the repo; making it one is a good M9 item. |
