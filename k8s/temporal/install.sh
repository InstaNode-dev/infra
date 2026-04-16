#!/usr/bin/env bash
# install.sh — Install Temporal on local k8s using platform Postgres as persistence.
#
# Prerequisites:
#   - helm >= 3.x
#   - kubectl configured for the target cluster
#   - Temporal databases already created:
#       kubectl exec -n instant deploy/postgres-platform -- \
#         psql -U instant -d instant_platform -c "CREATE DATABASE temporal;"
#       kubectl exec -n instant deploy/postgres-platform -- \
#         psql -U instant -d instant_platform -c "CREATE DATABASE temporal_visibility;"
#
# Usage:
#   ./infra/k8s/temporal/install.sh
#
# To uninstall:
#   helm uninstall temporal -n temporal
#   kubectl delete namespace temporal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="temporal"
RELEASE="temporal"
CHART="temporalio/temporal"

echo "► Adding temporalio Helm repo..."
helm repo add temporalio https://go.temporal.io/helm-charts 2>/dev/null || true
helm repo update temporalio

echo "► Creating namespace ${NAMESPACE}..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "► Installing/upgrading Temporal chart..."
helm upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --values "${SCRIPT_DIR}/helm-values.yaml" \
  --timeout 10m \
  --wait

echo "► Applying NodePort for frontend gRPC..."
kubectl apply -f "${SCRIPT_DIR}/nodeport.yaml"

echo "► Applying NetworkPolicy..."
kubectl apply -f "${SCRIPT_DIR}/networkpolicy.yaml"

echo "► Waiting for Temporal pods to be ready..."
kubectl rollout status deployment/temporal-frontend -n "${NAMESPACE}" --timeout=5m
kubectl rollout status deployment/temporal-history  -n "${NAMESPACE}" --timeout=5m
kubectl rollout status deployment/temporal-matching -n "${NAMESPACE}" --timeout=5m
kubectl rollout status deployment/temporal-worker   -n "${NAMESPACE}" --timeout=5m

echo ""
echo "✓ Temporal is running."
echo ""
echo "  Web UI:           http://localhost:30888"
echo "  gRPC (external):  localhost:30777"
echo "  gRPC (internal):  temporal-frontend.temporal.svc.cluster.local:7233"
echo ""
echo "  To switch migrator to Temporal engine:"
echo "    kubectl set env deployment/instant-migrator -n instant-infra \\"
echo "      WORKFLOW_ENGINE=temporal \\"
echo "      TEMPORAL_HOST=temporal-frontend.temporal.svc.cluster.local:7233"
echo "    kubectl rollout status deployment/instant-migrator -n instant-infra"
echo ""
echo "  E2E tests that use Temporal:"
echo "    E2E_MIGRATOR_URL=http://localhost:<migrator-nodeport> \\"
echo "    E2E_TEMPORAL_HOST=localhost:30777 \\"
echo "    E2E_JWT_SECRET=<secret> \\"
echo "    go test ./e2e/... -tags e2e -v -run TestE2E_Migrator -count=1"
