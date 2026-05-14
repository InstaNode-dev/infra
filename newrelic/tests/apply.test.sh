#!/usr/bin/env bash
#
# Tests for apply.sh. Run from anywhere:
#   bash newrelic/tests/apply.test.sh
#
# No real API calls — exercises argument parsing, env-var guards, JSON
# validation, and --dry-run output.

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
NR_DIR="$( cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd )"
APPLY="$NR_DIR/apply.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
    echo "  ok  $label"
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$label")
    echo "  FAIL $label"
    echo "       expected: $expected"
    echo "       actual:   $actual"
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS+1))
    echo "  ok  $label"
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$label")
    echo "  FAIL $label"
    echo "       expected to contain: $needle"
    echo "       actual: $haystack"
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS+1))
    echo "  ok  $label"
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$label")
    echo "  FAIL $label"
    echo "       expected NOT to contain: $needle"
    echo "       actual: $haystack"
  fi
}

# ----------------------------------------------------------------------------
echo "test: apply.sh is executable"
# ----------------------------------------------------------------------------
if [ -x "$APPLY" ]; then
  echo "  ok  apply.sh is executable"
  PASS=$((PASS+1))
else
  echo "  FAIL apply.sh is not executable"
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("executable bit")
fi

# ----------------------------------------------------------------------------
echo "test: missing NEW_RELIC_API_KEY exits 1 with stderr message"
# ----------------------------------------------------------------------------
out=$(env -i PATH="$PATH" "$APPLY" 2>&1 >/dev/null)
code=$?
assert_eq "exit code is 1" "1" "$code"
assert_contains "stderr mentions NEW_RELIC_API_KEY" "NEW_RELIC_API_KEY" "$out"

# ----------------------------------------------------------------------------
echo "test: missing NEW_RELIC_ACCOUNT_ID exits 1 with stderr message"
# ----------------------------------------------------------------------------
out=$(env -i PATH="$PATH" NEW_RELIC_API_KEY=fake "$APPLY" 2>&1 >/dev/null)
code=$?
assert_eq "exit code is 1" "1" "$code"
assert_contains "stderr mentions NEW_RELIC_ACCOUNT_ID" "NEW_RELIC_ACCOUNT_ID" "$out"

# ----------------------------------------------------------------------------
echo "test: --dry-run with both env vars set prints all 33 names, no API calls"
# ----------------------------------------------------------------------------
out=$(env -i PATH="$PATH" NEW_RELIC_API_KEY=fake NEW_RELIC_ACCOUNT_ID=1234567 \
  "$APPLY" --dry-run 2>&1)
code=$?
assert_eq "exit code is 0" "0" "$code"

# 5 base dashboard names (4 original + SLO rollup from W5-D)
assert_contains "dry-run prints api-overview"           "instant-api — overview"          "$out"
assert_contains "dry-run prints provisioning"           "instant-api — provisioning"      "$out"
assert_contains "dry-run prints deploy"                 "instant-api — deploy"            "$out"
assert_contains "dry-run prints worker dashboard"       "instant-worker — River jobs"     "$out"
assert_contains "dry-run prints slo-rollup"             "instant-api — SLO rollup"        "$out"

# 5 nr-config-rollup dashboard names (A1)
assert_contains "dry-run prints admin-defense"          "admin defense-in-depth"          "$out"
assert_contains "dry-run prints promote-approval"       "promote approval flow"           "$out"
assert_contains "dry-run prints billing-dunning"        "billing dunning + pricing"       "$out"
assert_contains "dry-run prints resource-lifecycle"     "resource pause/resume + deploy lifecycle" "$out"
assert_contains "dry-run prints ops-rollup"             "ops rollup"                      "$out"

# 2 W10 follow-up dashboard names
assert_contains "dry-run prints audit-feed-wave9"       "audit feed (W7/W8/W9 kinds)"     "$out"
assert_contains "dry-run prints backup-health"          "customer-visible backup health"  "$out"

# 5 base + 4 SLO alert names
assert_contains "dry-run prints error-rate alert"       "error rate > 1%"                 "$out"
assert_contains "dry-run prints p95-latency alert"      "p95 latency > 500ms"             "$out"
assert_contains "dry-run prints nats-down alert"        "NATS connection failures"        "$out"
assert_contains "dry-run prints worker-stalled alert"   "no jobs processed in 10m"        "$out"
assert_contains "dry-run prints api-5xx-rate alert"     "5xx rate > 1%"                   "$out"
assert_contains "dry-run prints slo-db-new alert"       "SLO POST /db/new success"        "$out"
assert_contains "dry-run prints slo-deploy-new alert"   "SLO POST /deploy/new success"    "$out"
assert_contains "dry-run prints slo-resources alert"    "SLO GET /api/v1/resources"       "$out"
assert_contains "dry-run prints slo-5xx-spike alert"    "SLO any-endpoint 5xx spike"      "$out"

# 7 nr-config-rollup alerts
assert_contains "dry-run prints admin-allowlist-breach"  "admin.access from non-allowlist user" "$out"
assert_contains "dry-run prints admin-probe-404-rate"    "ADMIN_PATH_PREFIX 404 rate"      "$out"
assert_contains "dry-run prints promote-bypass"          "promote.approved without prior approval_requested" "$out"
assert_contains "dry-run prints grace-terminated-spike"  "payment.grace_terminated spike"  "$out"
assert_contains "dry-run prints paused-resource-stale"   "resource paused > 30d"           "$out"
assert_contains "dry-run prints deploy-failure-rate"     "deploy failure rate > 30%"       "$out"
assert_contains "dry-run prints deploy-time-degraded"    "median deploy time > 5 min"      "$out"

# 5 W10 follow-up alert names
assert_contains "dry-run prints team-deletion alert"    "team.deletion_failed > 0"                     "$out"
assert_contains "dry-run prints storage-iam alert"      "storage IAM user create failures"             "$out"
assert_contains "dry-run prints decrypt-burst alert"    "connection_url.decrypted > 50/h"              "$out"
assert_contains "dry-run prints deploy-by-team alert"   "deploy failure rate > 30% (1h) faceted"       "$out"
assert_contains "dry-run prints backup-stuck alert"     "backup.requested with no follow-up"           "$out"

# No real HTTP traffic — the [dry-run] tag must appear on every name
# 12 dashboards + 21 alerts = 33 total after W10 follow-up.
dryrun_count=$(echo "$out" | grep -c '^\[dry-run\]' || true)
assert_eq "every name prefixed with [dry-run] (33 total)" "33" "$dryrun_count"

# ----------------------------------------------------------------------------
echo "test: --dry-run without env vars still validates JSON + warns"
# ----------------------------------------------------------------------------
out=$(env -i PATH="$PATH" "$APPLY" --dry-run 2>&1)
code=$?
assert_eq "exit code is 0 with no env (dry-run)" "0" "$code"
assert_contains "warns about unset env" "warning" "$out"
dryrun_count=$(echo "$out" | grep -c '^\[dry-run\]' || true)
assert_eq "still prints 33 [dry-run] entries" "33" "$dryrun_count"

# ----------------------------------------------------------------------------
echo "test: every JSON file in dashboards/ and alerts/ parses cleanly"
# ----------------------------------------------------------------------------
broken=0
for f in "$NR_DIR"/dashboards/*.json "$NR_DIR"/alerts/*.json; do
  if ! jq empty "$f" >/dev/null 2>&1; then
    echo "  FAIL invalid JSON: $f"
    broken=$((broken+1))
  fi
done
if [ "$broken" -eq 0 ]; then
<<<<<<< HEAD
  echo "  ok  all 26 JSON files parse"
=======
  echo "  ok  all 16 JSON files parse"
>>>>>>> b41339a (newrelic: dashboards + alerts for W7/W8/W9 audit kinds (W10 follow-up))
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("$broken JSON files don't parse")
fi

# ----------------------------------------------------------------------------
echo "test: corrupted JSON file causes dry-run to fail before printing names"
# ----------------------------------------------------------------------------
TMP_BAD="$NR_DIR/dashboards/_test_corrupt.json"
echo "{not valid json" > "$TMP_BAD"
out=$(env -i PATH="$PATH" NEW_RELIC_API_KEY=fake NEW_RELIC_ACCOUNT_ID=1234567 \
  "$APPLY" --dry-run 2>&1)
code=$?
rm -f "$TMP_BAD"
assert_eq "corrupt JSON => exit 1" "1" "$code"
assert_contains "error mentions invalid JSON" "invalid JSON" "$out"
assert_not_contains "no dashboard names printed before failure" "instant-api — overview" "$out"

# ----------------------------------------------------------------------------
echo "test: unknown flag exits 2"
# ----------------------------------------------------------------------------
out=$(env -i PATH="$PATH" NEW_RELIC_API_KEY=fake NEW_RELIC_ACCOUNT_ID=1234567 \
  "$APPLY" --foobar 2>&1 >/dev/null)
code=$?
assert_eq "unknown flag => exit 2" "2" "$code"
assert_contains "stderr mentions unknown flag" "unknown flag" "$out"

# ----------------------------------------------------------------------------
echo
echo "================================================"
echo "passed: $PASS    failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
echo "all tests pass."
