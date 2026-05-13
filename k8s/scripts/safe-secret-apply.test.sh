#!/usr/bin/env bash
#
# Tests for safe-secret-apply.sh. Run from anywhere:
#   bash k8s/scripts/safe-secret-apply.test.sh
#
# Exercises the guardrail without ever calling kubectl. We stub kubectl
# on $PATH so a "would-have-applied" test can succeed without a live
# cluster.

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APPLY="$SCRIPT_DIR/safe-secret-apply.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

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
    echo "       actual:              $haystack"
  fi
}

assert_status() {
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
    echo "       expected exit: $expected"
    echo "       actual exit:   $actual"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub kubectl that just echoes "APPLIED <args>" so the test can verify
# that the script reached the apply step without contacting any cluster.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "APPLIED $*"
EOF
chmod +x "$WORK/bin/kubectl"
PATH="$WORK/bin:$PATH"

# ─── Test 1: refuses a file containing CHANGE_ME (legacy keys) ────────────
echo "TEST: refuses CHANGE_ME in legacy keys"
cat > "$WORK/bad-legacy.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: instant-secrets
  namespace: instant
stringData:
  AES_KEY: "CHANGE_ME"
EOF
out=$("$APPLY" "$WORK/bad-legacy.yaml" 2>&1)
status=$?
assert_status "exit non-zero" "1" "$status"
assert_contains "complains about CHANGE_ME" "CHANGE_ME" "$out"
assert_contains "names the offending file" "$WORK/bad-legacy.yaml" "$out"

# ─── Test 2: refuses the new ADMIN_PATH_PREFIX placeholder ────────────────
# Validates that the existing guardrail picks up the new field's
# CHANGE_ME placeholder text. The placeholder we ship in secrets.yaml is
# "CHANGE_ME_64char_random_alphanumeric" — the guard greps for the
# substring CHANGE_ME, so any reasonable placeholder triggers.
echo "TEST: refuses ADMIN_PATH_PREFIX placeholder"
cat > "$WORK/bad-admin-path.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: instant-secrets
  namespace: instant
stringData:
  ADMIN_PATH_PREFIX: "CHANGE_ME_64char_random_alphanumeric"
EOF
out=$("$APPLY" "$WORK/bad-admin-path.yaml" 2>&1)
status=$?
assert_status "exit non-zero" "1" "$status"
assert_contains "complains about CHANGE_ME" "CHANGE_ME" "$out"

# ─── Test 3: refuses ADMIN_EMAILS placeholder ─────────────────────────────
echo "TEST: refuses ADMIN_EMAILS placeholder"
cat > "$WORK/bad-admin-emails.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: instant-secrets
  namespace: instant
stringData:
  ADMIN_EMAILS: "CHANGE_ME_comma_separated_admin_emails"
EOF
out=$("$APPLY" "$WORK/bad-admin-emails.yaml" 2>&1)
status=$?
assert_status "exit non-zero" "1" "$status"

# ─── Test 4: accepts a file with real-looking values ──────────────────────
echo "TEST: accepts file with real values"
cat > "$WORK/good.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: instant-secrets
  namespace: instant
stringData:
  ADMIN_EMAILS: "founder@instanode.dev"
  ADMIN_PATH_PREFIX: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  AES_KEY: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
EOF
out=$("$APPLY" "$WORK/good.yaml" 2>&1)
status=$?
assert_status "exits zero when no CHANGE_ME present" "0" "$status"
assert_contains "reaches kubectl apply" "APPLIED" "$out"

# ─── Test 5: refuses non-existent file ────────────────────────────────────
echo "TEST: refuses non-existent file"
out=$("$APPLY" "$WORK/does-not-exist.yaml" 2>&1)
status=$?
assert_status "exit non-zero" "1" "$status"

# ─── Test 6: refuses no-argument invocation ───────────────────────────────
echo "TEST: refuses no-argument call"
out=$("$APPLY" 2>&1)
status=$?
assert_status "exit non-zero" "1" "$status"
assert_contains "shows usage" "usage" "$out"

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ $FAIL -ne 0 ]; then
  echo ""
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
echo "─────────────────────────────────────"
