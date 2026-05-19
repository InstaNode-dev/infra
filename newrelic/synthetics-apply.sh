#!/usr/bin/env bash
#
# synthetics-apply.sh — apply the synthetics/*.json monitor definitions to the
# live New Relic account via NerdGraph (Synthetics mutations).
#
# Companion to apply.sh (dashboards + alerts). Kept separate because synthetic
# monitors use a different family of NerdGraph mutations
# (syntheticsCreateSimpleMonitor / syntheticsCreateScriptApiMonitor / etc.)
# from the dashboard + alert mutations apply.sh drives.
#
# Idempotent: creates on first run, updates on subsequent runs by looking up
# monitors by name (entitySearch type='MONITOR').
#
# Usage:
#   NEW_RELIC_API_KEY=NRAK-... NEW_RELIC_ACCOUNT_ID=7958263 ./synthetics-apply.sh
#   ./synthetics-apply.sh --dry-run     # validate JSON, print plan, no API calls
#
# Required env vars:
#   NEW_RELIC_API_KEY        User Key (NRAK-...) with Synthetics admin scope.
#   NEW_RELIC_ACCOUNT_ID     Numeric account ID (instanode.dev prod = 7958263).
#
# Optional env vars:
#   NEW_RELIC_REGION         "US" (default) or "EU".

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "missing dep: curl" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "missing dep: jq"   >&2; exit 1; }

if [ "$DRY_RUN" -eq 0 ]; then
  [ -n "${NEW_RELIC_API_KEY:-}" ]    || { echo "set NEW_RELIC_API_KEY" >&2;    exit 1; }
  [ -n "${NEW_RELIC_ACCOUNT_ID:-}" ] || { echo "set NEW_RELIC_ACCOUNT_ID" >&2; exit 1; }
fi

REGION="${NEW_RELIC_REGION:-US}"
case "$REGION" in
  US) NERDGRAPH_URL="https://api.newrelic.com/graphql" ;;
  EU) NERDGRAPH_URL="https://api.eu.newrelic.com/graphql" ;;
  *) echo "NEW_RELIC_REGION must be US or EU (got: $REGION)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SYNTH_DIR="$SCRIPT_DIR/synthetics"

# Validate every JSON file parses before any API call.
for f in "$SYNTH_DIR"/*.json; do
  [ -f "$f" ] || continue
  jq empty "$f" >/dev/null 2>&1 || { echo "invalid JSON: $f" >&2; exit 1; }
done

nerdgraph() {
  local query="$1"
  local variables="${2:-{\}}"
  local payload resp
  payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')
  resp=$(curl -sS -X POST "$NERDGRAPH_URL" \
    -H "Content-Type: application/json" \
    -H "API-Key: $NEW_RELIC_API_KEY" \
    -d "$payload")
  if echo "$resp" | jq -e '.errors // empty' >/dev/null 2>&1; then
    echo "nerdgraph error:" >&2
    echo "$resp" | jq '.errors' >&2
    return 1
  fi
  echo "$resp"
}

# Find an existing monitor GUID by exact name.
find_monitor_guid() {
  local name="$1"
  local query='query($q: String!) {
    actor { entitySearch(query: $q) { results { entities { guid name } } } }
  }'
  local q="type = 'MONITOR' AND name = '$name' AND accountId = $NEW_RELIC_ACCOUNT_ID"
  local vars
  vars=$(jq -n --arg q "$q" '{q: $q}')
  nerdgraph "$query" "$vars" \
    | jq -r --arg n "$name" '.data.actor.entitySearch.results.entities[]
        | select(.name == $n) | .guid' \
    | head -n1
}

apply_monitor() {
  local file="$1"
  local kind name period status
  kind=$(jq -r '.monitorKind' "$file")
  name=$(jq -r '.name' "$file")
  period=$(jq -r '.period' "$file")
  status=$(jq -r '.status' "$file")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $kind monitor: $name  ($file)"
    return 0
  fi

  local existing
  existing=$(find_monitor_guid "$name" || true)

  local locations
  locations=$(jq -c '[.locations[] | {label: .}] | {public: [.[].label]}' "$file")

  case "$kind" in
    SIMPLE)
      local uri
      uri=$(jq -r '.uri' "$file")
      if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        local m='mutation($guid: EntityGuid!, $monitor: SyntheticsUpdateSimpleMonitorInput!) {
          syntheticsUpdateSimpleMonitor(guid: $guid, monitor: $monitor) {
            errors { description } monitor { guid name } } }'
        local v
        v=$(jq -n --arg guid "$existing" --arg name "$name" --arg uri "$uri" \
          --arg period "$period" --arg status "$status" --argjson loc "$locations" \
          '{guid: $guid, monitor: {name: $name, uri: $uri, period: $period, status: $status, locations: $loc}}')
        nerdgraph "$m" "$v" >/dev/null && echo "+ $name (SIMPLE, updated)"
      else
        local m='mutation($accountId: Int!, $monitor: SyntheticsCreateSimpleMonitorInput!) {
          syntheticsCreateSimpleMonitor(accountId: $accountId, monitor: $monitor) {
            errors { description } monitor { guid name } } }'
        local v
        v=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --arg name "$name" --arg uri "$uri" \
          --arg period "$period" --arg status "$status" --argjson loc "$locations" \
          '{accountId: $a, monitor: {name: $name, uri: $uri, period: $period, status: $status, locations: $loc}}')
        nerdgraph "$m" "$v" >/dev/null && echo "+ $name (SIMPLE, created)"
      fi
      ;;
    BROWSER)
      local uri
      uri=$(jq -r '.uri' "$file")
      local runtime
      runtime=$(jq -c '.runtime' "$file")
      if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        local m='mutation($guid: EntityGuid!, $monitor: SyntheticsUpdateSimpleBrowserMonitorInput!) {
          syntheticsUpdateSimpleBrowserMonitor(guid: $guid, monitor: $monitor) {
            errors { description } monitor { guid name } } }'
        local v
        v=$(jq -n --arg guid "$existing" --arg name "$name" --arg uri "$uri" \
          --arg period "$period" --arg status "$status" --argjson loc "$locations" --argjson rt "$runtime" \
          '{guid: $guid, monitor: {name: $name, uri: $uri, period: $period, status: $status, locations: $loc, runtime: $rt}}')
        nerdgraph "$m" "$v" >/dev/null && echo "+ $name (BROWSER, updated)"
      else
        local m='mutation($accountId: Int!, $monitor: SyntheticsCreateSimpleBrowserMonitorInput!) {
          syntheticsCreateSimpleBrowserMonitor(accountId: $accountId, monitor: $monitor) {
            errors { description } monitor { guid name } } }'
        local v
        v=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --arg name "$name" --arg uri "$uri" \
          --arg period "$period" --arg status "$status" --argjson loc "$locations" --argjson rt "$runtime" \
          '{accountId: $a, monitor: {name: $name, uri: $uri, period: $period, status: $status, locations: $loc, runtime: $rt}}')
        nerdgraph "$m" "$v" >/dev/null && echo "+ $name (BROWSER, created)"
      fi
      ;;
    SCRIPT_API)
      local script_file script
      script_file="$SYNTH_DIR/$(jq -r '.scriptFile' "$file")"
      [ -f "$script_file" ] || { echo "x $name — script file missing: $script_file" >&2; return 1; }
      script=$(cat "$script_file")
      local runtime
      runtime=$(jq -c '.runtime' "$file")
      if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        local m='mutation($guid: EntityGuid!, $monitor: SyntheticsUpdateScriptApiMonitorInput!) {
          syntheticsUpdateScriptApiMonitor(guid: $guid, monitor: $monitor) {
            errors { description } monitor { guid name } } }'
        local v
        v=$(jq -n --arg guid "$existing" --arg name "$name" --arg period "$period" \
          --arg status "$status" --arg script "$script" --argjson loc "$locations" --argjson rt "$runtime" \
          '{guid: $guid, monitor: {name: $name, period: $period, status: $status, script: $script, locations: $loc, runtime: $rt}}')
        nerdgraph "$m" "$v" >/dev/null && echo "+ $name (SCRIPT_API, updated)"
      else
        local m='mutation($accountId: Int!, $monitor: SyntheticsCreateScriptApiMonitorInput!) {
          syntheticsCreateScriptApiMonitor(accountId: $accountId, monitor: $monitor) {
            errors { description } monitor { guid name } } }'
        local v
        v=$(jq -n --argjson a "$NEW_RELIC_ACCOUNT_ID" --arg name "$name" --arg period "$period" \
          --arg status "$status" --arg script "$script" --argjson loc "$locations" --argjson rt "$runtime" \
          '{accountId: $a, monitor: {name: $name, period: $period, status: $status, script: $script, locations: $loc, runtime: $rt}}')
        nerdgraph "$m" "$v" >/dev/null && echo "+ $name (SCRIPT_API, created)"
      fi
      ;;
    *)
      echo "x $name — unknown monitorKind: $kind" >&2
      return 1
      ;;
  esac
}

echo "==> NerdGraph endpoint: $NERDGRAPH_URL"
echo "==> Account: ${NEW_RELIC_ACCOUNT_ID:-<unset>}"
[ "$DRY_RUN" -eq 1 ] && echo "==> DRY RUN — no API calls will be made."
echo
echo "==> Synthetic monitors"

FAILURES=()
for f in "$SYNTH_DIR"/*.json; do
  [ -f "$f" ] || continue
  if ! apply_monitor "$f"; then
    FAILURES+=("$(basename "$f")")
  fi
done

echo
if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "==> Done with ${#FAILURES[@]} failure(s):"
  for x in "${FAILURES[@]}"; do echo "    x $x"; done
  exit 1
fi
echo "==> Done."
