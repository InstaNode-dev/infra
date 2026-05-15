#!/usr/bin/env bash
#
# apply.sh — apply the dashboards/*.json and alerts/*.json JSON files
# (committed in api PR #34) to the live New Relic account via NerdGraph.
#
# Idempotent: creates on first run, updates on subsequent runs by looking up
# resources by name in the account.
#
# Usage:
#   NEW_RELIC_API_KEY=NRAK-... NEW_RELIC_ACCOUNT_ID=1234567 ./apply.sh
#   ./apply.sh --dry-run        # print what would happen, no API calls
#
# Required env vars:
#   NEW_RELIC_API_KEY        User Key (NRAK-...) with admin permissions to
#                            manage dashboards + alert policies. NOT the
#                            license key (NRAL-...) — that's ingest-only.
#   NEW_RELIC_ACCOUNT_ID     Numeric account ID. Found at
#                            https://one.newrelic.com → Account dropdown.
#
# Optional env vars:
#   NEW_RELIC_REGION         "US" (default) or "EU". Controls the NerdGraph
#                            endpoint host.
#   NEW_RELIC_POLICY_NAME    Override the default policy name
#                            ("instant-api alerts") that all NRQL conditions
#                            are attached to.

set -euo pipefail

# ----------------------------------------------------------------------------
# Args + env
# ----------------------------------------------------------------------------

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

# ----------------------------------------------------------------------------
# Dependency checks
# ----------------------------------------------------------------------------

command -v curl >/dev/null 2>&1 || { echo "missing dep: curl" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "missing dep: jq"   >&2; exit 1; }

if [ "$DRY_RUN" -eq 0 ]; then
  [ -n "${NEW_RELIC_API_KEY:-}" ]    || { echo "set NEW_RELIC_API_KEY" >&2;    exit 1; }
  [ -n "${NEW_RELIC_ACCOUNT_ID:-}" ] || { echo "set NEW_RELIC_ACCOUNT_ID" >&2; exit 1; }
else
  # In dry-run, still require the env vars so the operator catches missing
  # config before the real run. If both are missing we treat that as a no-call
  # smoke test — but warn loudly.
  if [ -z "${NEW_RELIC_API_KEY:-}" ] || [ -z "${NEW_RELIC_ACCOUNT_ID:-}" ]; then
    echo "warning: NEW_RELIC_API_KEY or NEW_RELIC_ACCOUNT_ID unset — dry-run only validates JSON." >&2
  fi
fi

REGION="${NEW_RELIC_REGION:-US}"
case "$REGION" in
  US) NERDGRAPH_URL="https://api.newrelic.com/graphql" ;;
  EU) NERDGRAPH_URL="https://api.eu.newrelic.com/graphql" ;;
  *) echo "NEW_RELIC_REGION must be US or EU (got: $REGION)" >&2; exit 1 ;;
esac

POLICY_NAME="${NEW_RELIC_POLICY_NAME:-instant-api alerts}"

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DASHBOARDS_DIR="$SCRIPT_DIR/dashboards"
ALERTS_DIR="$SCRIPT_DIR/alerts"

# ----------------------------------------------------------------------------
# Validate JSON before any API call
# ----------------------------------------------------------------------------

for f in "$DASHBOARDS_DIR"/*.json "$ALERTS_DIR"/*.json; do
  [ -f "$f" ] || continue
  jq empty "$f" >/dev/null 2>&1 || { echo "invalid JSON: $f" >&2; exit 1; }
done

# ----------------------------------------------------------------------------
# NerdGraph helper — POST a GraphQL query, return data field or fail
# ----------------------------------------------------------------------------

nerdgraph() {
  local query="$1"
  local variables="${2:-{\}}"
  local payload
  payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')
  local resp
  resp=$(curl -sS -X POST "$NERDGRAPH_URL" \
    -H "Content-Type: application/json" \
    -H "API-Key: $NEW_RELIC_API_KEY" \
    -d "$payload")
  # Fail loud on errors. NerdGraph returns 200 with an errors[] array.
  if echo "$resp" | jq -e '.errors // empty' >/dev/null 2>&1; then
    echo "nerdgraph error:" >&2
    echo "$resp" | jq '.errors' >&2
    return 1
  fi
  echo "$resp"
}

# ----------------------------------------------------------------------------
# Dashboard: substitute accountIds:[0] placeholder with real account
# ----------------------------------------------------------------------------

prepare_dashboard() {
  local file="$1"
  # Walk every nrqlQueries[*].accountIds and replace [0] with [$account].
  jq --argjson account "${NEW_RELIC_ACCOUNT_ID:-0}" '
    walk(
      if type == "object" and has("accountIds") then
        .accountIds = [$account]
      else . end
    )
  ' "$file"
}

# ----------------------------------------------------------------------------
# Find existing dashboard by name
# ----------------------------------------------------------------------------

find_dashboard_guid() {
  local name="$1"
  local query='query($q: String!) {
    actor {
      entitySearch(query: $q) {
        results { entities { guid name } }
      }
    }
  }'
  local q="type = 'DASHBOARD' AND name = '$name' AND accountId = $NEW_RELIC_ACCOUNT_ID"
  local vars
  vars=$(jq -n --arg q "$q" '{q: $q}')
  nerdgraph "$query" "$vars" \
    | jq -r --arg n "$name" '.data.actor.entitySearch.results.entities[]
      | select(.name == $n) | .guid' \
    | head -n1
}

# ----------------------------------------------------------------------------
# Apply one dashboard (create or update)
# ----------------------------------------------------------------------------

apply_dashboard() {
  local file="$1"
  local name
  name=$(jq -r '.name' "$file")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] dashboard: $name  ($file)"
    return 0
  fi

  local body
  body=$(prepare_dashboard "$file")

  local existing
  existing=$(find_dashboard_guid "$name" || true)

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    # Update
    # NerdGraph's DashboardEntityResult exposes guid but NOT permalink
    # (the field was removed from the schema). Build the redirect URL
    # from the guid instead.
    local mutation='mutation($guid: EntityGuid!, $dashboard: DashboardInput!) {
      dashboardUpdate(guid: $guid, dashboard: $dashboard) {
        errors { description type }
        entityResult { guid }
      }
    }'
    local vars
    vars=$(jq -n --arg guid "$existing" --argjson d "$body" '{guid: $guid, dashboard: $d}')
    local resp
    resp=$(nerdgraph "$mutation" "$vars")
    local errs
    errs=$(echo "$resp" | jq -r '.data.dashboardUpdate.errors // [] | length')
    if [ "$errs" -gt 0 ]; then
      echo "x $name — update errors:" >&2
      echo "$resp" | jq '.data.dashboardUpdate.errors' >&2
      return 1
    fi
    local guid
    guid=$(echo "$resp" | jq -r '.data.dashboardUpdate.entityResult.guid')
    echo "+ $name (updated)  https://one.newrelic.com/redirect/entity/${guid}"
  else
    # Create
    local mutation='mutation($accountId: Int!, $dashboard: DashboardInput!) {
      dashboardCreate(accountId: $accountId, dashboard: $dashboard) {
        errors { description type }
        entityResult { guid }
      }
    }'
    local vars
    vars=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --argjson d "$body" \
      '{accountId: $a, dashboard: $d}')
    local resp
    resp=$(nerdgraph "$mutation" "$vars")
    local errs
    errs=$(echo "$resp" | jq -r '.data.dashboardCreate.errors // [] | length')
    if [ "$errs" -gt 0 ]; then
      echo "x $name — create errors:" >&2
      echo "$resp" | jq '.data.dashboardCreate.errors' >&2
      return 1
    fi
    local guid
    guid=$(echo "$resp" | jq -r '.data.dashboardCreate.entityResult.guid')
    echo "+ $name (created)  https://one.newrelic.com/redirect/entity/${guid}"
  fi
}

# ----------------------------------------------------------------------------
# Alert policy: find-or-create the umbrella policy
# ----------------------------------------------------------------------------

ensure_policy() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "0" # sentinel — never used in dry-run
    return 0
  fi
  local query='query($accountId: Int!) {
    actor {
      account(id: $accountId) {
        alerts {
          policiesSearch(searchCriteria: {}) {
            policies { id name }
          }
        }
      }
    }
  }'
  local vars
  vars=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" '{accountId: $a}')
  local existing
  existing=$(nerdgraph "$query" "$vars" \
    | jq -r --arg n "$POLICY_NAME" \
      '.data.actor.account.alerts.policiesSearch.policies[]
        | select(.name == $n) | .id' \
    | head -n1)
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "$existing"
    return 0
  fi
  # Create
  local mutation='mutation($accountId: Int!, $policy: AlertsPolicyInput!) {
    alertsPolicyCreate(accountId: $accountId, policy: $policy) {
      id name
    }
  }'
  local vars2
  vars2=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --arg n "$POLICY_NAME" \
    '{accountId: $a, policy: {name: $n, incidentPreference: "PER_CONDITION"}}')
  nerdgraph "$mutation" "$vars2" \
    | jq -r '.data.alertsPolicyCreate.id'
}

# ----------------------------------------------------------------------------
# Find existing NRQL condition by name within a policy
# ----------------------------------------------------------------------------

find_condition_id() {
  local policy_id="$1"
  local name="$2"
  local query='query($accountId: Int!, $policyId: ID!) {
    actor {
      account(id: $accountId) {
        alerts {
          nrqlConditionsSearch(searchCriteria: {policyId: $policyId}) {
            nrqlConditions { id name }
          }
        }
      }
    }
  }'
  local vars
  vars=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --arg p "$policy_id" \
    '{accountId: $a, policyId: $p}')
  nerdgraph "$query" "$vars" \
    | jq -r --arg n "$name" \
      '.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions[]
        | select(.name == $n) | .id' \
    | head -n1
}

# ----------------------------------------------------------------------------
# Apply one alert NRQL condition (create or update)
# ----------------------------------------------------------------------------

apply_alert() {
  local file="$1"
  local policy_id="$2"
  local name
  name=$(jq -r '.name' "$file")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] alert: $name  ($file)"
    return 0
  fi

  # Strip the "type" field — it's not part of NrqlConditionStaticInput.
  # Everything else (name, description, enabled, nrql, terms, signal,
  # expiration, violationTimeLimitSeconds) maps directly.
  local body
  body=$(jq 'del(.type)' "$file")

  local existing
  existing=$(find_condition_id "$policy_id" "$name" || true)

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    local mutation='mutation($accountId: Int!, $id: ID!, $condition: NrqlConditionUpdateInput!) {
      alertsNrqlConditionStaticUpdate(accountId: $accountId, id: $id, condition: $condition) {
        id name
      }
    }'
    local vars
    vars=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --arg id "$existing" --argjson c "$body" \
      '{accountId: $a, id: $id, condition: $c}')
    # nerdgraph returns non-zero on a GraphQL errors[] array. The `|| true`
    # keeps this function alive so the caller's failure list captures it
    # (an aborted function would kill the whole alert loop).
    local resp
    resp=$(nerdgraph "$mutation" "$vars") || true
    local id
    id=$(echo "$resp" | jq -r '.data.alertsNrqlConditionStaticUpdate.id // empty')
    if [ -z "$id" ]; then
      echo "x $name — update failed (see nerdgraph error above)" >&2
      return 1
    fi
    echo "+ $name (updated)  https://one.newrelic.com/alerts-ai/condition-builder/static-condition/${id}"
  else
    local mutation='mutation($accountId: Int!, $policyId: ID!, $condition: NrqlConditionStaticInput!) {
      alertsNrqlConditionStaticCreate(accountId: $accountId, policyId: $policyId, condition: $condition) {
        id name
      }
    }'
    local vars
    vars=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --arg p "$policy_id" --argjson c "$body" \
      '{accountId: $a, policyId: $p, condition: $c}')
    local resp
    resp=$(nerdgraph "$mutation" "$vars") || true
    local id
    id=$(echo "$resp" | jq -r '.data.alertsNrqlConditionStaticCreate.id // empty')
    if [ -z "$id" ]; then
      echo "x $name — create failed (see nerdgraph error above)" >&2
      return 1
    fi
    echo "+ $name (created)  https://one.newrelic.com/alerts-ai/condition-builder/static-condition/${id}"
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

echo "==> NerdGraph endpoint: $NERDGRAPH_URL"
echo "==> Account: ${NEW_RELIC_ACCOUNT_ID:-<unset>}"
echo "==> Policy:  $POLICY_NAME"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> DRY RUN — no API calls will be made."
fi
echo

echo "==> Dashboards"
for f in "$DASHBOARDS_DIR"/*.json; do
  [ -f "$f" ] || continue
  apply_dashboard "$f"
done

echo
echo "==> Alerts"
POLICY_ID=$(ensure_policy)
if [ "$DRY_RUN" -eq 0 ]; then
  echo "    policy id: $POLICY_ID"
fi
# Resilient apply: one bad alert (e.g. NRQL the alert engine rejects —
# subqueries are not permitted in alert conditions) must not abort the
# remaining ~20. Collect failures, report at the end, exit non-zero so
# CI still notices, but every applicable alert lands.
ALERT_FAILURES=()
for f in "$ALERTS_DIR"/*.json; do
  [ -f "$f" ] || continue
  if ! apply_alert "$f" "$POLICY_ID"; then
    ALERT_FAILURES+=("$(basename "$f")")
  fi
done

echo
if [ "${#ALERT_FAILURES[@]}" -gt 0 ]; then
  echo "==> Done with ${#ALERT_FAILURES[@]} alert failure(s):"
  for fail in "${ALERT_FAILURES[@]}"; do
    echo "    x $fail"
  done
  exit 1
fi
echo "==> Done."
