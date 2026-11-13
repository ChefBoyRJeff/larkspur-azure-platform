# Idempotency check for the deploy workflow.
# Input: az deployment group what-if --no-pretty-print -o json
# Output: an array of real drift items ({resource, path, change}). An empty array means the deployed state matches
#         the code.
#
# Known what-if noise is filtered out by rule, and every rule is documented in the README:
#   - DNS zone groups: read-only etag/id/provisioningState/type inside privateDnsZoneConfigs (M3).
#   - properties.runningStatus: read-only status of a container app (M4b).
#   - properties.configuration.ingress.exposedPort: TCP-only setting Azure stores as 0 for HTTP apps (M4b).
#   - values shown as "[reference(...)]": what-if can't resolve references into another resource group, so it prints
#     the expression instead of the value (M4a/M4b). The deployed value is checked functionally by the smoke tests.

def leaves: if ((.children // []) | length) > 0 then .children[] | leaves else . end;

[
  .changes[]
  | select(.changeType != "NoChange" and .changeType != "Ignore")
  | select((.resourceId | test("/privateDnsZoneGroups/")) | not)
  | .resourceId as $rid
  | if .changeType == "Modify" then
      .delta[]
      | leaves
      | select(.path != "properties.runningStatus")
      | select(.path != "properties.configuration.ingress.exposedPort")
      | select(((.after | type) == "string" and (.after | startswith("[reference("))) | not)
      | {resource: ($rid | split("/") | last), path: .path, change: .propertyChangeType}
    else
      {resource: ($rid | split("/") | last), path: "(whole resource)", change: .changeType}
    end
]
