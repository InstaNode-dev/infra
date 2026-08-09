#!/bin/bash
set -euo pipefail

# apply-all.sh — clean-cluster bring-up, in dependency order.
#
# REWRITTEN 2026-08-09 for the DigitalOcean → Azure AKS port. The previous
# version was missing four things that each independently prevent a clean
# cluster from ever reaching Ready:
#
#   1. RBAC was never applied. `app.yaml` sets `serviceAccountName: instant-api`
#      and `worker/deployment.yaml` sets `serviceAccountName: instant-worker`,
#      but neither `deploy-rbac.yaml` (which creates the first) nor
#      `worker-rbac.yaml` (the second) was in the script. A Deployment naming a
#      nonexistent ServiceAccount produces pods that are never admitted, with
#      the reason buried in the ReplicaSet's events rather than the pod's.
#   2. `data/` was applied BEFORE the secrets its pods consume, so
#      postgres-customers came up in CreateContainerConfigError and had to be
#      restarted by hand.
#   3. `postgres-platform.yaml` was applied unconditionally. It is LOCAL-DEV
#      ONLY — prod platform Postgres is external (Azure Database for PostgreSQL
#      Flexible Server). Applying it on Azure creates a second, empty,
#      unreferenced Postgres holding a PVC. See the LOCAL_DEV flag below.
#   4. Nothing applied the ingress/TLS layer, the data-tier hardening
#      (NetworkPolicy / PDBs / pg_hba lockdown), or the metrics pipeline.
#
# USAGE
#   ./apply-all.sh                 # Azure/prod bring-up
#   LOCAL_DEV=1 ./apply-all.sh     # also apply the in-cluster platform Postgres
#
# THIS SCRIPT IS FOR FRESH CLUSTERS ONLY. For in-place changes to a running
# cluster read k8s/APPLY-CHECKLIST.md (api/worker/provisioner Deployments) and
# k8s/DATA-TIER-APPLY-RUNBOOK.md (anything holding customer data) — both have
# dry-run + verification gates this script deliberately does not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV="${LOCAL_DEV:-0}"

echo "▶ target context: $(kubectl config current-context)"
echo "  Ctrl-C now if that is not the cluster you meant."
sleep 5

# ── 1. Namespaces ────────────────────────────────────────────────────────────
# Must be first: everything below is namespaced. Kubernetes auto-labels each
# namespace with `kubernetes.io/metadata.name`, which is what the data-tier
# NetworkPolicy namespaceSelectors match on — no manual labelling needed.
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"

# ── 2. RBAC ──────────────────────────────────────────────────────────────────
# Before any workload: a Deployment naming a ServiceAccount that does not exist
# yet produces pods that are never admitted.
kubectl apply -f "$SCRIPT_DIR/deploy-rbac.yaml"            # SA instant-api + deploy-manager
kubectl apply -f "$SCRIPT_DIR/instant-namespace-rbac.yaml" # instant-api within-ns grants
kubectl apply -f "$SCRIPT_DIR/worker-rbac.yaml"            # SA instant-worker + deploy-reader
kubectl apply -f "$SCRIPT_DIR/provisioner/rbac.yaml"       # SA instant-provisioner
kubectl apply -f "$SCRIPT_DIR/ci-deployer-rbac.yaml"       # SA ci-deployer (kube-system) for CI

# ── 3. Secrets + config ──────────────────────────────────────────────────────
# BEFORE workloads — a pod whose secretKeyRef is unresolvable sits in
# CreateContainerConfigError and does not self-heal on secret creation without
# a restart.
#
# ⚠️ Every value in these templates is CHANGE_ME. Applying them over a cluster
# that already has real secrets CLOBBERS them. Use scripts/safe-secret-apply.sh
# on anything that is not a genuinely fresh cluster.
kubectl apply -f "$SCRIPT_DIR/secrets.yaml"           # instant-secrets       (ns instant)
kubectl apply -f "$SCRIPT_DIR/infra-secrets.yaml"     # instant-infra-secrets (ns instant-infra)
kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/migrations-configmap.yaml"

# GHCR pull secrets. NOT templated in this repo (they carry a real PAT). Every
# backend Deployment lists `ghcr-pull` plus one of `ghcr-org-pull`/`ghcr-regrade`
# in imagePullSecrets; without them every pod lands in ImagePullBackOff.
#   kubectl create secret docker-registry ghcr-pull -n <ns> \
#     --docker-server=ghcr.io --docker-username=<user> --docker-password=<PAT>
for ns in instant instant-infra; do
  kubectl get secret ghcr-pull -n "$ns" >/dev/null 2>&1 \
    || echo "  ⚠️  missing secret ghcr-pull in ns $ns — pods will ImagePullBackOff"
done

# ── 4. Data tier ─────────────────────────────────────────────────────────────
# PriorityClass (cluster-scoped) + PDBs first so the workloads can reference
# them, then the pg_hba lockdown ConfigMap (postgres-customers.yaml mounts it
# via subPath — apply it first or the pod cannot start), then the workloads.
kubectl apply -f "$SCRIPT_DIR/data/stateful-priority.yaml"
kubectl apply -f "$SCRIPT_DIR/data/postgres-customers-lockdown.yaml"
kubectl apply -f "$SCRIPT_DIR/data/postgres-customers.yaml"
kubectl apply -f "$SCRIPT_DIR/data/redis-provision.yaml"
kubectl apply -f "$SCRIPT_DIR/data/mongodb.yaml"
kubectl apply -f "$SCRIPT_DIR/data/nats.yaml"

echo "▶ waiting for data-tier PVCs to bind (managed-csi on AKS)…"
kubectl wait --for=jsonpath='{.status.phase}'=Bound --timeout=300s \
  -n instant-data pvc/postgres-customers-pvc pvc/redis-provision-pvc \
  pvc/mongodb-pvc pvc/nats-jetstream-pvc \
  || {
    echo "  ✗ a PVC did not bind. On AKS the usual cause is a StorageClass that"
    echo "    does not exist — check for a leftover 'local-path' (k3s-only):"
    echo "      kubectl get storageclass"
    echo "      kubectl get pvc -n instant-data"
    exit 1
  }

# NetworkPolicy LAST in this section: it default-denies ingress to every data
# pod, so applying it before the pods exist is harmless but applying it before
# you have verified the allow list is how customers get cut off. Read the header
# of the file (and DATA-TIER-APPLY-RUNBOOK.md §S2) before trusting it.
#
# ⚠️ These are INERT unless the cluster was created with a network policy
# engine. On AKS that is a create-time setting. Verify:
#   az aks show -g <rg> -n <cluster> --query networkProfile.networkPolicy
kubectl apply -f "$SCRIPT_DIR/data/networkpolicy.yaml"

# ── 5. Platform Postgres (LOCAL DEV ONLY) ────────────────────────────────────
# Prod uses Azure Database for PostgreSQL Flexible Server, external to the
# cluster, holding BOTH instant_platform and provisioner_db. DATABASE_URL /
# PROVISIONER_DATABASE_URL point there.
if [ "$LOCAL_DEV" = "1" ]; then
  echo "▶ LOCAL_DEV=1 — applying in-cluster postgres-platform"
  kubectl apply -f "$SCRIPT_DIR/postgres-platform.yaml"
else
  echo "▶ skipping postgres-platform.yaml (local-dev only; prod = Azure Flexible Server)"
fi

# ── 6. Platform services ─────────────────────────────────────────────────────
kubectl apply -f "$SCRIPT_DIR/redis.yaml"        # platform Redis (ns instant)
kubectl apply -f "$SCRIPT_DIR/provisioner/"      # rbac re-applied here, idempotent
kubectl apply -f "$SCRIPT_DIR/app.yaml"          # instant-api
kubectl apply -f "$SCRIPT_DIR/worker/"
kubectl apply -f "$SCRIPT_DIR/website.yaml"
kubectl apply -f "$SCRIPT_DIR/nats-proxy/"

# ── 7. Node image cache ──────────────────────────────────────────────────────
# Pre-pulls the DB images so a dedicated per-tenant provision is not gated on a
# cold pull. Pinned OFF the Spot pool — see k8s/spot/README.md.
kubectl apply -f "$SCRIPT_DIR/image-puller.yaml"

# ── 8. Ingress + TLS ─────────────────────────────────────────────────────────
# Requires cert-manager AND ingress-nginx to be installed first (Helm — see
# k8s/ingress/README.md), and the DNS A record to already resolve to the LB IP,
# or the HTTP-01 challenge fails and burns Let's Encrypt rate limit.
if kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
  kubectl apply -f "$SCRIPT_DIR/ingress/"
else
  echo "▶ skipping ingress/ — cert-manager CRDs not installed."
  echo "  See k8s/ingress/README.md, then: kubectl apply -f k8s/ingress/"
fi

# ── 9. Observability ─────────────────────────────────────────────────────────
# The ONLY metrics scraper in the cluster. Without it every New Relic
# `FROM Metric WHERE metricName LIKE 'instant_%'` alert queries an empty stream
# and is silently inert (memory: project_nr_metric_alerts_inert_no_prom_pipeline).
#
# ⚠️ Create the real secret FIRST, then apply everything EXCEPT the placeholder
# Secret document in that file — applying it would clobber the real key with
# CHANGE_ME and CrashLoop the agent. Full procedure: APPLY-CHECKLIST.md.
if kubectl get secret newrelic-prometheus-agent-secrets -n newrelic >/dev/null 2>&1; then
  if command -v yq >/dev/null 2>&1; then
    yq 'select(.kind != "Secret")' "$SCRIPT_DIR/newrelic-prometheus-agent.yaml" | kubectl apply -f -
  else
    echo "▶ skipping newrelic-prometheus-agent — yq not installed (needed to strip"
    echo "  the placeholder Secret). See APPLY-CHECKLIST.md for the manual apply."
  fi
else
  echo "▶ skipping newrelic-prometheus-agent — secret/newrelic-prometheus-agent-secrets"
  echo "  not created yet. See APPLY-CHECKLIST.md § New Relic Prometheus agent."
fi

# ── NOT applied here, deliberately ───────────────────────────────────────────
#   migrator/                       — NOT bring-up ready. `instant-migrator:local`
#                                     + imagePullPolicy: Never can never pull on
#                                     AKS, and WORKFLOW_ENGINE=temporal points at
#                                     a Temporal stack this script does not
#                                     install, so /health never passes. Full
#                                     detail in the header of
#                                     migrator/deployment.yaml. It handles
#                                     RESOURCE migrations, not the api's schema
#                                     migrations, so nothing in the serving path
#                                     depends on it.
#   self-hosted-runner.yaml         — competes with the platform for the single
#                                     node; CI uses GitHub-hosted runners.
#   preview/                        — per-PR ephemeral envs, own runbook
#                                     (infra/PREVIEW-ENV-RUNBOOK.md).
#   canary/                         — needs Argo Rollouts CRDs.
#   temporal/                       — optional stack, own install.sh.
#   spot/spot-scheduling-policy.yaml — needs Kyverno; see k8s/spot/README.md.
#   provisioner/mtls.yaml           — scaffold, needs cert-manager CRDs.

echo
echo "▶ bring-up applied. Verify:"
echo "    kubectl get pods -A | grep -Ev 'Running|Completed'"
echo "    kubectl get pvc -A"
echo "    kubectl get certificate -n instant        # Ready=True once DNS resolves"
echo "    curl -sS https://api.instanode.dev/healthz | jq .commit_id"
