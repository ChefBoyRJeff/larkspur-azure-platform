# INC-001: New SQL servers refused in East US

| | |
|---|---|
| **Date** | 11-12-2026, 04:20 PM–09:00 PM EST |
| **Milestone** | M3 (data and secrets) |
| **Impact** | Data tier blocked: the SQL server couldn't be created, so its private endpoint failed too. No data or running services affected (nothing was live yet). |
| **Status** | Resolved: SQL server deployed in Central US; private endpoint connects to it from vnet-lark in East US |

## Symptoms

1. The first data-tier deployment failed on the SQL server:
   `RegionDoesNotAllowProvisioning: Location 'East US' is not accepting creation of new Windows Azure SQL Database servers at this time.`
   The SQL private endpoint then failed with `SubscriptionDoesNotHaveServer`, a downstream effect.
2. After I moved the server to East US 2, the deployment failed before reaching the region with
   `InvalidResourceLocation: The resource 'sql-lark-…' already exists in location 'eastus'`, even though no SQL
   server existed in the resource group.
3. With a new name, East US 2 failed with the same `RegionDoesNotAllowProvisioning` error.

Evidence: [`m3-01`](../evidence/m3-01-data-tier.txt), [`m3-02`](../evidence/m3-02-data-tier-region-fix.txt),
[`m3-04`](../evidence/m3-04-data-tier.txt)

## Investigation

My first hypothesis was a temporary capacity problem in East US, which is why I tried the next-closest region. When
East US 2 failed the same way, I stopped trying regions one at a time and asked Azure directly: the SQL
**capabilities API** (`Microsoft.Sql/locations/{region}/capabilities`) reports, per subscription and region, whether
new servers can be provisioned and why not.

| Region | Status | Reason |
|---|---|---|
| eastus, eastus2, northcentralus, westus, westus2 | `Visible` | "Provisioning is restricted in this region… open a support request with Issue type of 'Service and subscription limits'" |
| centralus, southcentralus, westcentralus, westus3 | `Available` | none |

Evidence: [`m3-05-sql-region-probe.txt`](../evidence/m3-05-sql-region-probe.txt)

The probe matched the failures exactly (both regions I'd hit were restricted), so I trusted it for the rest.

## Root cause

1. **Subscription-level provisioning restriction.** My subscription is restricted from creating new SQL servers in
   the busiest US regions. It isn't an outage: it's a standing limit that Microsoft lifts only through a support
   request.
2. **Name reserved by the failed attempt.** Resource Manager kept a record of the server name in the region where
   creation was attempted, so the same name couldn't be created in another region. My naming function hashed only the
   subscription ID, so it produced the same name for every region.

## Remediation

| Change | File |
|---|---|
| SQL server and database in **Central US** (closest available region); Key Vault, network and everything else stay in East US | `infra/data/main.bicep` (`sqlLocation`), `infra/app/main.bicepparam` |
| Region added to the SQL name hash: `uniqueString(subscriptionId, 'larkspur-azure-platform', location)` | `infra/shared/naming.bicep` |
| `rg-lark-data` alone allows `eastus` + `centralus`; `rg-lark-app` stays East US only | `infra/governance/main.bicep` (`dataAllowedLocations`) |

The private endpoint stays in vnet-lark (East US). Private Link supports connecting to a resource in another region,
so the app's path to the database is unchanged.

I considered moving the whole platform to Central US. I rejected it because the Key Vault already existed in East US
with purge protection: deleting it would have reserved its deterministic name for 7 days.

## Verification

- SQL server created in `centralus`; free-tier database online. ([`m3-06`](../evidence/m3-06-data-tier.txt))
- `pe-lark-sql` (East US) `Approved`; `sql-lark-…` resolves to 10.60.1.5 inside the VNet.
- Policy shows `rg-lark-data` allowed locations `["eastus","centralus"]`.

## Prevention

- **Check capacity before choosing a region.** The capabilities probe takes seconds and is now the first step
  whenever a region is chosen for SQL.
- **Region-aware names** for resources whose names are global DNS names, so a failed attempt in one region can't
  block another.
- **Fail fast in deployment scripts.** My first run kept executing after the failure and produced misleading
  follow-on errors; every block now runs inside a script block that stops at the first failed step.
- **Production path:** open a "Service and subscription limits" support request for the preferred region, and keep
  the data tier in the same region as the app where latency matters.
