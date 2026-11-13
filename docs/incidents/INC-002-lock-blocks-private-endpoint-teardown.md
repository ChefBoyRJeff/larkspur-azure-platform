# INC-002: Resource lock blocked private endpoint teardown

| | |
|---|---|
| **Date** | 11-12-2026, 04:38 PM–04:44 PM EST |
| **Milestone** | M3 (data and secrets) |
| **Impact** | End-of-session teardown stopped; `pe-lark-kv` couldn't be deleted, so it would have kept billing (~$0.01/hr) |
| **Status** | Resolved: lock moved to the database; Key Vault protected by soft delete + purge protection |

## Symptoms

My teardown script stopped while deleting the Key Vault private endpoint:

```
ScopeLocked: The scope '.../vaults/kv-lark-.../privateEndpointConnectionProxies/pe-lark-kv...' cannot perform
delete operation because following scope(s) are locked: '.../vaults/kv-lark-...'
```

The lock was the `CanNotDelete` lock I had put on the Key Vault itself, not on anything in `rg-lark-app`.

Evidence: [`m3-03-data-tier.txt`](../evidence/m3-03-data-tier.txt)

## Root cause

When a private endpoint is created, Azure also creates a **connection record on the target resource**: a child of
the Key Vault (and, for SQL, a child of the logical server). Deleting the endpoint deletes that child. A
`CanNotDelete` lock applies to a resource **and all of its children**, so the vault's lock blocked the endpoint's
deletion. A lock on the SQL server would have done the same.

My design had a conflict built in: locks on the targets, plus private endpoints that are created and deleted every
session.

## Options considered

| Option | Decision |
|---|---|
| Keep the private endpoints running permanently | Rejected: ~$15/month for two endpoints, against the project's cost goal |
| Have the teardown script remove the locks, delete, and re-lock | Rejected: a lock that automation routinely removes isn't a control |
| **Put protection where the data is** | Chosen |

## Remediation

- **SQL:** the lock moved from the server to the **database** (`lock-sqldb-lark-tracking`). Private endpoint
  connections are children of the server, not the database, so teardown works while the data stays protected.
- **Key Vault:** lock removed. Soft delete (7 days) plus purge protection already guarantee recovery: a deleted
  vault or secret can be restored, and nobody, including an Owner, can purge it early. The lock only duplicated that
  protection while blocking a normal operation.
- Because incremental deployments don't delete resources removed from a template, I deleted the old vault lock
  explicitly before redeploying.

Files: `infra/data/modules/sql.bicep`, `infra/data/modules/keyvault.bicep`

## Verification

| Check | Result |
|---|---|
| Teardown after removing the vault lock | Both private endpoints deleted, `rg-lark-app` empty ([`m3-04`](../evidence/m3-04-data-tier.txt)) |
| Delete the database with its lock in place | `ScopeLocked`; database still present ([`m3-06`](../evidence/m3-06-data-tier.txt)) |
| Teardown with the database lock in place | Both endpoints deleted; DNS zone groups removed both A records ([`m3-07`](../evidence/m3-07-drift-network-test-teardown.txt)) |
| Key Vault protection | `purgeProtection: true`, `softDeleteDays: 7` |

## Prevention

- **Locks cascade to children, including children Azure creates for you.** Before locking a resource, I check what
  other workflows create or delete child resources under it (private endpoint connections, diagnostic settings,
  role assignments).
- Prefer a service's native recovery features (soft delete, purge protection, backups) where they protect the data
  better than a lock does.
- This is the second time a lock's scope mattered in this project: in M1 I moved a planned resource-group lock for
  the same reason (it would have blocked deleting the private DNS zone links).
