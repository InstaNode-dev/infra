#!/usr/bin/env bash
# Refuses to apply a secrets YAML if any CHANGE_ME values present.
#
# Background: `k8s/secrets.yaml` and `k8s/infra-secrets.yaml` are TEMPLATES
# containing `CHANGE_ME` placeholders. A naive `kubectl apply -f secrets.yaml`
# will overwrite real production secrets (AES_KEY, JWT_SECRET, RAZORPAY_*, etc.)
# with the literal string `CHANGE_ME` and crashloop dependent pods.
#
# This script guards against that mistake by refusing to apply any YAML
# that still contains a `CHANGE_ME` token.
#
# Usage:
#   ./k8s/scripts/safe-secret-apply.sh k8s/secrets.local.yaml
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "usage: $0 <secrets-yaml>" >&2
    exit 1
fi

if [ ! -f "$1" ]; then
    echo "REFUSED: $1 does not exist." >&2
    exit 1
fi

if grep -q "CHANGE_ME" "$1"; then
    echo "REFUSED: $1 contains CHANGE_ME placeholders." >&2
    echo "Use 'kubectl patch secret ... --type=merge' to update individual keys;" >&2
    echo "do not apply the whole file." >&2
    echo "See k8s/README.md section 'Secret operations — DO NOT naive-apply'." >&2
    exit 1
fi

kubectl apply -f "$1"
