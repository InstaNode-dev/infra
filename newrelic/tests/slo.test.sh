#!/usr/bin/env bash
#
# Tests for the SLO rollup dashboard + 4 SLO alerts + the k8s probe split.
# Run from anywhere:
#   bash newrelic/tests/slo.test.sh
#
# Mirrors newrelic/tests/apply.test.sh — no real API calls, exercises
# JSON validity, widget/alert counts, and k8s manifest probe-shape
# assertions (3-probe split + failure-threshold values).

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
NR_DIR="$( cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd )"
REPO_DIR="$( cd -- "$NR_DIR/.." &> /dev/null && pwd )"

DASH_FILE="$NR_DIR/dashboards/slo-rollup.json"
ALERTS_DIR="$NR_DIR/alerts"
K8S_DIR="$REPO_DIR/k8s"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1)); echo "  ok  $label"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$label")
    echo "  FAIL $label"
    echo "       expected: $expected"
    echo "       actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS+1)); echo "  ok  $label"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$label")
    echo "  FAIL $label"
    echo "       expected to contain: $needle"
  fi
}

assert_file_has_probe() {
  local label="$1" file="$2" probe="$3" path_value="$4"
  # Look for the probe block + the httpGet.path on the same path. yq would
  # be cleaner but we don't depend on it — grep -A is enough for the shape
  # check ("does this probe block reference the right path?").
  local block
  block=$(grep -A 2 "${probe}:" "$file" | grep "path: ${path_value}" || true)
  if [ -n "$block" ]; then
    PASS=$((PASS+1)); echo "  ok  $label"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$label")
    echo "  FAIL $label"
    echo "       expected ${probe} → ${path_value} in $file"
  fi
}

# ----------------------------------------------------------------------------
echo "test: slo-rollup.json parses as valid JSON"
# ----------------------------------------------------------------------------
if jq empty "$DASH_FILE" >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "  ok  slo-rollup.json parses"
else
  FAIL=$((FAIL+1)); FAILED_TESTS+=("slo-rollup.json invalid")
  echo "  FAIL slo-rollup.json invalid JSON"
fi

# ----------------------------------------------------------------------------
echo "test: slo-rollup.json has the 6 required widgets plus markdown context"
# ----------------------------------------------------------------------------
# 6 widgets per the brief: success-rate-by-endpoint, latency-by-endpoint,
# provisioning success-rate, 4 budget-burn bullets (4 separate widgets),
# top-errors table, provisioner-gRPC line. = 9 NRQL widgets total.
# Plus the markdown "About this dashboard" panel = 10. Count is widgets in the
# only page.
widget_count=$(jq '.pages[0].widgets | length' "$DASH_FILE")
assert_eq "slo-rollup widget count == 10" "10" "$widget_count"

# Each of the 4 SLO targets must have its own bullet widget
for target in "POST /db/new" "POST /deploy/new" "GET /api/v1/resources" "POST /webhook/new"; do
  if jq -e --arg t "$target" '.pages[0].widgets[] | select(.title | contains($t))' "$DASH_FILE" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "  ok  slo-rollup includes SLO target widget: $target"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("missing SLO target widget: $target")
    echo "  FAIL slo-rollup missing widget for: $target"
  fi
done

# ----------------------------------------------------------------------------
echo "test: 4 SLO alert files exist and parse"
# ----------------------------------------------------------------------------
declare -a EXPECTED_ALERTS=(
  "slo-db-new-success-rate.json"
  "slo-deploy-new-success-rate.json"
  "slo-resources-p95-latency.json"
  "slo-5xx-spike.json"
)
broken=0
for a in "${EXPECTED_ALERTS[@]}"; do
  f="$ALERTS_DIR/$a"
  if [ ! -f "$f" ]; then
    echo "  FAIL missing alert file: $a"
    broken=$((broken+1))
  elif ! jq empty "$f" >/dev/null 2>&1; then
    echo "  FAIL invalid JSON: $a"
    broken=$((broken+1))
  fi
done
if [ "$broken" -eq 0 ]; then
  PASS=$((PASS+1)); echo "  ok  all 4 SLO alert files exist and parse"
else
  FAIL=$((FAIL+1)); FAILED_TESTS+=("$broken SLO alert files missing/invalid")
fi

# ----------------------------------------------------------------------------
echo "test: SLO alert thresholds match the brief"
# ----------------------------------------------------------------------------
# /db/new success: BELOW 99.5
db_thr=$(jq -r '.terms[] | select(.priority == "CRITICAL") | .threshold' \
  "$ALERTS_DIR/slo-db-new-success-rate.json")
assert_eq "/db/new critical threshold == 99.5" "99.5" "$db_thr"

# /deploy/new success: BELOW 99.0 (jq emits "99" for the integer 99; the
# JSON stores it as 99.0 which jq normalizes — so we compare as a number).
deploy_thr=$(jq -r '.terms[] | select(.priority == "CRITICAL") | .threshold' \
  "$ALERTS_DIR/slo-deploy-new-success-rate.json")
assert_eq "/deploy/new critical threshold == 99.0" "99.0" "$deploy_thr"

# /api/v1/resources p95: ABOVE 200
res_thr=$(jq -r '.terms[] | select(.priority == "CRITICAL") | .threshold' \
  "$ALERTS_DIR/slo-resources-p95-latency.json")
assert_eq "/api/v1/resources p95 threshold == 200" "200" "$res_thr"

# 5xx spike: ABOVE 5.0
spike_thr=$(jq -r '.terms[] | select(.priority == "CRITICAL") | .threshold' \
  "$ALERTS_DIR/slo-5xx-spike.json")
assert_eq "5xx spike critical threshold == 5.0" "5.0" "$spike_thr"

# ----------------------------------------------------------------------------
echo "test: k8s manifests carry the 3-probe split (startup + readiness + liveness)"
# ----------------------------------------------------------------------------
declare -a APP_DEPLOYS=(
  "$K8S_DIR/app.yaml"
  "$K8S_DIR/provisioner/deployment.yaml"
  "$K8S_DIR/worker/deployment.yaml"
  "$K8S_DIR/migrator/deployment.yaml"
)
for f in "${APP_DEPLOYS[@]}"; do
  base=$(basename "$(dirname "$f")")/$(basename "$f")
  for probe in startupProbe readinessProbe livenessProbe; do
    if grep -q "$probe:" "$f"; then
      PASS=$((PASS+1)); echo "  ok  $base has $probe"
    else
      FAIL=$((FAIL+1)); FAILED_TESTS+=("$base missing $probe")
      echo "  FAIL $base missing $probe"
    fi
  done
done

# ----------------------------------------------------------------------------
echo "test: liveness probes hit /livez (not /healthz) on app + provisioner + worker"
# ----------------------------------------------------------------------------
assert_file_has_probe "app.yaml livenessProbe → /livez"          "$K8S_DIR/app.yaml"                   "livenessProbe" "/livez"
assert_file_has_probe "provisioner livenessProbe → /livez"       "$K8S_DIR/provisioner/deployment.yaml" "livenessProbe" "/livez"
assert_file_has_probe "worker livenessProbe → /livez"            "$K8S_DIR/worker/deployment.yaml"     "livenessProbe" "/livez"
assert_file_has_probe "migrator livenessProbe → /livez"          "$K8S_DIR/migrator/deployment.yaml"   "livenessProbe" "/livez"

# ----------------------------------------------------------------------------
echo "test: startupProbe failureThreshold is 60 (10 min) on all 4 app Deployments"
# ----------------------------------------------------------------------------
for f in "${APP_DEPLOYS[@]}"; do
  base=$(basename "$(dirname "$f")")/$(basename "$f")
  # Pull the failureThreshold under startupProbe specifically. awk because
  # we want the value scoped to the startupProbe block, not other probes'.
  threshold=$(awk '/startupProbe:/{flag=1} flag && /failureThreshold:/{print $2; exit}' "$f")
  assert_eq "$base startupProbe.failureThreshold == 60" "60" "$threshold"
done

# ----------------------------------------------------------------------------
echo "test: kubectl dry-run accepts every modified manifest"
# ----------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  dry_fail=0
  for f in "${APP_DEPLOYS[@]}"; do
    if ! kubectl apply --dry-run=client -f "$f" >/dev/null 2>&1; then
      echo "  FAIL kubectl rejected: $f"
      dry_fail=$((dry_fail+1))
    fi
  done
  if [ "$dry_fail" -eq 0 ]; then
    PASS=$((PASS+1)); echo "  ok  all 4 manifests pass kubectl --dry-run=client"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$dry_fail manifests rejected by kubectl")
  fi
else
  echo "  skip kubectl not installed (would have run --dry-run=client on 4 manifests)"
fi

# ----------------------------------------------------------------------------
# Manual NR smoke checklist (no automation — per memory rule, every change
# must surface its observability. The probe-split rollout doesn't have an
# auto-alert because k8s pod restart counts are infra-level; the operator
# needs to eyeball them post-deploy.)
# ----------------------------------------------------------------------------
echo
echo "================================================"
echo "MANUAL NR SMOKE STEPS after the probe-split deploy:"
echo "  1. Open instant-api — overview dashboard, watch error-rate widget"
echo "     for 30 min after rollout. Spike past 1% = roll back."
echo "  2. NRQL: SELECT count(*) FROM K8sContainerSample"
echo "     WHERE clusterName = 'instant' AND restartCount > 0"
echo "     FACET podName SINCE 1 hour ago"
echo "     — expect 0 unexpected restarts; only the rolling-update churn."
echo "  3. Confirm new SLO dashboard renders all 4 budget-bullet widgets"
echo "     within 5 min of running newrelic/apply.sh."
echo "  4. Open SLO POST /db/new alert in NR alerts UI, confirm it shows"
echo "     'no signal' (not 'breaching') for the first 30 min of data ingest."
echo "================================================"

echo
echo "passed: $PASS    failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
echo "all tests pass."
