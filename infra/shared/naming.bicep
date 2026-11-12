// Shared naming for resources whose names must be globally unique (they become DNS names).
// Both stacks import these functions, so infra/data (which creates the resources) and infra/app (which points
// private endpoints at them) can never disagree on a name.
//
// uniqueString() is deterministic: the same subscription always gets the same 13-character suffix, so redeploys
// target the same resources instead of creating new ones.

@export()
@description('SQL logical server name: sql-lark-<suffix> (becomes <name>.database.windows.net). The region is part of the hash because Resource Manager reserves a name in the region where creation was attempted (INC-001).')
func larkSqlServerName(subscriptionId string, location string) string => 'sql-lark-${uniqueString(subscriptionId, 'larkspur-azure-platform', location)}'

@export()
@description('Key Vault name: kv-lark-<suffix> (24 characters max; becomes <name>.vault.azure.net)')
func larkKeyVaultName(subscriptionId string) string => 'kv-lark-${uniqueString(subscriptionId, 'larkspur-azure-platform')}'
