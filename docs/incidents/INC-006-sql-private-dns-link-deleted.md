# INC-006: The SQL private DNS zone lost its VNet link

| | |
|---|---|
| **Date** | 11-17-2026, 02:40 PM–03:47 PM EST |
| **Milestone** | M8 (operational incidents) |
| **Type** | Deliberate M8 incident: I deleted the link in the portal as a realistic "cleanup" mistake, then worked it as on-call |
| **Impact** | Every shipment lookup and readiness check failed for 62 min 56 s (11 requests were made: 1 x 503, 10 x 500). Key Vault was unaffected. |
| **Status** | Resolved by redeploying the app stack through the pipeline; verified from the internet and from inside the VNet |

## Symptoms

- `/readyz` returned **HTTP 503**. Its DNS check said `ok` but showed a **public** address for the SQL server, and
  the SQL check failed with *"Connection was denied because Deny Public Network Access is set to Yes"*. Key Vault
  stayed healthy.
- 10 parallel lookups of `/shipments/LRK100001` returned **HTTP 500 x 10** (02:49–02:52 PM).
- `alert-lark-api-5xx` emailed me at **03:00 PM**.

My first symptom check (02:34 PM) showed everything healthy. The activity log later showed why: I ran it before I
had actually deleted the link (02:40:35 PM). I kept that attempt in the evidence; it's why I now confirm a change is
in place before reading symptoms.

Evidence: [`m8-01`](../evidence/m8-01-baseline.txt) (healthy baseline),
[`m8-02`](../evidence/m8-02-inc006-symptoms.txt)

## Investigation

I worked it as if I didn't know what had changed. Each check either ruled a hypothesis out or confirmed it
([`m8-03`](../evidence/m8-03-inc006-diagnosis.txt)):

| Hypothesis | Check | Result |
|---|---|---|
| H1: the network path is blocked (NSG) | The error text | Ruled out: a blocked path times out. "Connection was denied…" means the request reached a SQL gateway and was refused. |
| H2: someone re-enabled or changed SQL public access | `az sql server show --query publicNetworkAccess` | Ruled out: `Disabled`, as designed |
| H3: the private endpoint is broken | Endpoint connection state; IP from its NIC | Ruled out: `Approved`, 10.60.1.5 (the IP isn't in `customDnsConfigs` when a DNS zone group is used, so I read it from the NIC) |
| H4: the zone lost its A record | Record sets in `privatelink.database.windows.net` | Ruled out: `sql-lark-…` → 10.60.1.5 |
| H5: the VNet isn't using the zone | VNet links on both zones; in-VNet DNS (`scripts/Test-LarkPrivateDns.ps1`) | **Confirmed:** the SQL zone had **no VNet links**; the Key Vault zone still had `link-vnet-lark`. From inside the VNet, SQL resolved to a public IP and Key Vault to 10.60.1.4. |
| Who and when | Activity log, `virtualNetworkLinks` operations | `delete` Succeeded **02:40:35 PM**, caller a user |
| Customer impact | KQL on `ContainerAppHTTPLogs` | 0 errors before the delete; 1 x 5xx in 02:45–02:50 and 10 x 5xx in 02:50–02:55 |

## Root cause

The VNet link from `privatelink.database.windows.net` to `vnet-lark` was deleted. A private DNS zone only answers
for VNets linked to it, so `vnet-lark` fell back to public DNS. Public DNS returns the SQL server's public gateway
address, and the server refuses public connections. Nothing was wrong with SQL, the private endpoint or the record:
the app was simply asking the wrong DNS.

## Remediation

I redeployed the app stack with the `deploy` pipeline instead of recreating the link in the portal, because the link
is defined in code (`infra/app/modules/dns-links.bicep`) and a portal fix would be one more change the code doesn't
know about.

- The pipeline's what-if reported the drift: `+ Create …/privatelink.database.windows.net/virtualNetworkLinks/link-vnet-lark`,
  with the Key Vault link `= NoChange`.
- `gh-lark-deploy` recreated the link at 03:42 PM (activity log: caller a service principal).
- The smoke tests require `/readyz` to resolve SQL to `10.60.1.x`, so a green run is itself proof of the fix.
  Idempotency passed.

## Verification

[`m8-04`](../evidence/m8-04-inc006-fix.txt): both zones linked again; in-VNet DNS SQL → 10.60.1.5, Key Vault →
10.60.1.4; pe-lark-sql's NIC at 10.60.1.5; **HTTP 200 x 10**.

| Time (EST) | Event |
|---|---|
| 02:40:35 PM | VNet link deleted (portal, a user) |
| 02:42 PM | In-VNet DNS: SQL resolves to a public IP |
| 02:49–02:52 PM | 11 x HTTP 5xx |
| 03:00 PM | `alert-lark-api-5xx` fired (email) |
| 03:11 PM | Root cause confirmed |
| **03:21 PM** | **Alert auto-resolved while the link was still missing** |
| 03:23 PM | Fix started: `deploy` (waited for my approval until 03:41 PM) |
| 03:43:31 PM | Link recreated |
| 03:47:13 PM | Smoke tests pass; `/readyz` resolves SQL to 10.60.1.5 |

- **Impact window:** 62 min 56 s (delete to fix).
- **Time to detect:** about 8–11 minutes after the first failed request; 19 min 25 s after the delete, because no one
  called the API until 02:49.
- **Time to recover:** 43 min 31 s from the alert, of which 18 minutes was the deploy waiting for my approval.

## What I learned

- **An auto-resolved alert isn't a fix.** The 5xx alert counts failed requests in a 15-minute window. With no traffic
  after 02:52 PM, the count fell to zero and the alert resolved at 03:21 PM, 26 minutes before the real fix. To an
  alert that counts failures, "no traffic" looks the same as "healthy". I close an incident on a verified check, never
  on the resolve email.
- **"SQL is down" was a DNS problem.** The error text pointed the way: a refusal, not a timeout.
- **Check the change is real before reading symptoms.** My first check ran before the delete.

## Prevention

| Option | Decision |
|---|---|
| A `CanNotDelete` lock on the zone | **Rejected.** Locks cover child resources, so it would also stop teardown deleting the link every session, the same trap as INC-002. |
| Least privilege: only the pipeline changes DNS links | **Already the design for everyone but me.** `lark-ops` and `lark-dev` are Reader on both groups; I broke it as Owner. In production, Owner would be a break-glass role, not a daily one. |
| Drift repair through the pipeline | **In place.** A redeploy recreates the link, and its what-if shows exactly what drifted. |
| In-VNet DNS check as a runbook step | **Built:** `scripts/Test-LarkPrivateDns.ps1` shows what the app resolves, not what my PC resolves. |
| Outside-in availability test (a scheduled `/readyz` call) | **Proposed, not built.** It would keep traffic flowing so the alert stays red until the cause is fixed. The trade-off: it keeps the free database awake and spends vCore-seconds, which is incident 5's subject. |
| Activity log alert on `virtualNetworkLinks/delete` | **Proposed, not built.** It would also fire on every teardown; activity log alert conditions match a caller with equals, not "not equals", so I'd route it to a low-priority channel rather than page on it. |
