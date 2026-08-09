# Apply Checklist — Deployment Manifests

> Codified 2026-05-20 after a near-miss where applying the repo's
> `app.yaml` would have stripped `imagePullSecrets`, reset the image to
> `instant-api:local`, and added a `wait-for-platform-db` init container
> that blocks forever in prod. See "What went wrong" at the bottom.

> **Building a cluster from scratch?** This file is for **in-place updates to a
> running cluster**. For a clean AKS bring-up, start at
> [§ AKS clean-cluster bring-up](#aks-clean-cluster-bring-up-2026-08-09) at the
> bottom, which owns the ordering; then come back here for subsequent updates.

This checklist applies to:

- `infra/k8s/app.yaml` — `Deployment/instant-api` in namespace `instant`
- `infra/k8s/worker/deployment.yaml` — `Deployment/instant-worker` in `instant-infra`
- `infra/k8s/provisioner/deployment.yaml` — `Deployment/instant-provisioner` in `instant-infra`

Per CLAUDE.md rule 15: **this repo has no auto-apply by design.** Manifest
apply is a deliberate, human-driven step.

> **Stateful data-tier manifests** (`k8s/data/*` — postgres-customers,
> mongodb, redis-provision, nats: PVCs, NetworkPolicy, pg_hba lockdown,
> PriorityClass/PDBs) have their own apply order + verification gates in
> **`k8s/DATA-TIER-APPLY-RUNBOOK.md`**. Use that for S1/S2/R6/R7. This file
> is for the api/worker/provisioner Deployment manifests only.

---

## Hard rules

1. **DO NOT `kubectl apply -f k8s/app.yaml` against prod without first
   running `kubectl apply --dry-run=server` and reading the diff line by
   line.** The dry-run reveals exactly what the apply will change. If the
   diff includes anything other than the image tag, STOP and investigate.

2. **`imagePullSecrets` MUST be present** on every deployment manifest:

   | Deployment | Required secrets |
   |---|---|
   | `instant-api` | `ghcr-pull`, `ghcr-org-pull` |
   | `instant-worker` | `ghcr-pull`, `ghcr-regrade` |
   | `instant-provisioner` | `ghcr-pull`, `ghcr-regrade` |

   Without these, new pods land in `ImagePullBackOff`. The auto-deploy CI
   (which sets the image via `kubectl set image`) cannot repair stripped
   `imagePullSecrets` — it only touches the image field.

3. **The image tag in this file is a placeholder.** The actual prod image
   is set by the per-service auto-deploy CI in the api/worker/provisioner
   repos via:

   ```
   kubectl set image deploy/<name> <container>=ghcr.io/instanode-dev/<image>:master-<sha>
   ```

   The placeholder `:placeholder` is intentional — if a literal apply
   ever reaches prod, the pull will fail loudly (`ErrImagePull`) instead
   of silently regressing to a stale image. Loud failure > silent regression.

4. **Init containers that reference in-cluster services that don't
   exist in prod are removed from the base manifest.** The legacy
   `wait-for-platform-db` (and provisioner's `wait-for-provisioner-db`)
   init containers expected an in-cluster `postgres-platform` /
   `postgres-provisioner` Service. Prod uses EXTERNAL managed Postgres
   (Azure Database for PostgreSQL Flexible Server since 2026-08-09; DO
   Managed Postgres before that) — those Services do not exist. Init
   containers would block pod startup indefinitely.

   For local dev (Rancher Desktop / k3s with an in-cluster postgres pod),
   layer a kustomize overlay or just patch the init container in by hand:

   ```
   kubectl patch deploy/instant-api -n instant --type=json -p='[
     {"op":"add","path":"/spec/template/spec/initContainers","value":[
       {"name":"wait-for-platform-db","image":"postgres:16-alpine",
        "command":["sh","-c","until pg_isready -h postgres-platform -U instant -d instant_platform; do sleep 2; done"]}
     ]}
   ]'
   ```

5. **`terminationGracePeriodSeconds`, `lifecycle.preStop`, and graceful-
   shutdown probes must stay codified** (MR-P0-7, 2026-05-20). The api
   needs 35s (5s preStop + 3s readiness drain + 25s Fiber drain + 2s
   buffer) — anything less and k8s SIGKILLs mid-drain. The worker drains
   River jobs in `Workers.Stop` (MR-P0-2/P1-3) and needs the default 30s.

6. **`E2E_TEST_TOKEN` is declared ONCE on `instant-api`.** Earlier live
   manifests had two `env[E2E_TEST_TOKEN]` entries — kubectl raised a
   `hides previous definition` warning. The repo manifest declares it
   exactly once with `optional: true`.

---

## Standard pre-apply procedure

```bash
# 1. Confirm context
kubectl config current-context
# Expected: instanode-prod-aks (for prod) or rancher-desktop (for local).
# ⚠️ The retired DO context was `do-nyc3-instant-prod`. If you still see it,
#    your kubeconfig is stale — it points at a cluster that no longer exists
#    and every command below will hang on the dead doctl exec-credential
#    plugin. `kubectl config delete-context do-nyc3-instant-prod`.

# 2. Dry-run server-side (validates against the real API server, surfaces
#    schema errors AND shows what would change without changing anything)
kubectl apply --dry-run=server -f k8s/app.yaml

# 3. Diff against live (this is the SOURCE OF TRUTH for what apply will do)
diff <(kubectl apply --dry-run=server -f k8s/app.yaml -o yaml 2>/dev/null) \
     <(kubectl get deploy/instant-api -n instant -o yaml)

# 4. Read every line of the diff. Acceptable drift:
#    - image tag (will be overwritten by the next auto-deploy CI run)
#    - status block (read-only, computed by the controller)
#    - metadata.resourceVersion, generation (managed by the API server)
#    Anything else → STOP, investigate.

# 5. If the diff is clean, apply
kubectl apply -f k8s/app.yaml

# 6. After apply, immediately re-trigger the auto-deploy CI in the
#    api/worker/provisioner repo (or `kubectl set image` manually) to
#    restore the real image tag.
```

---

## What goes in the manifest vs the cluster

The manifest is the **structural** source of truth: deployment shape,
container names, env var declarations (with `valueFrom` references),
probes, resource limits, imagePullSecrets, volumeMounts.

The cluster is the **value** source of truth for secrets and the
current image tag:

- All `secretKeyRef`-resolved env vars get their values from
  `instant-secrets` / `instant-infra-secrets` (live in the cluster, NOT
  in this repo — see `secrets.yaml` template warning in `README.md`).
- The image tag is owned by the per-service auto-deploy CI on push to
  master in each backend repo.

If you add a new `secretKeyRef` env var here, you must ALSO
`kubectl patch secret instant-secrets ...` (or `instant-infra-secrets`)
with the real value — the manifest only declares the reference, it
doesn't seed the secret.

---

## What went wrong (2026-05-20 near-miss)

The repo's `app.yaml` had drifted away from live prod over several
weeks of incremental `kubectl patch` and `kubectl set image` operations
that never made it back into the file:

| Drift | Repo before fix | Live |
|---|---|---|
| `imagePullSecrets` | absent | `ghcr-pull`, `ghcr-org-pull` |
| Container image | `instant-api:local` | `ghcr.io/instanode-dev/instant-api:master-<sha>` |
| `wait-for-platform-db` initContainer | present | absent (DO Managed Postgres) |
| `OTEL_EXPORTER_OTLP_HEADERS` env | absent | present (NR license key) |
| `BUILD_IMAGE_REGISTRY` / `DEPLOY_DOMAIN` / `CERT_ISSUER` env | absent | present |
| `RAZORPAY_PLAN_ID_*_YEARLY` env | absent | present |
| `OBJECT_STORE_*` env (7 keys) | absent | present |
| `GITHUB_CLIENT_ID` / `GOOGLE_CLIENT_ID` env | absent | present |
| `E2E_TEST_TOKEN` env | absent (live had 2 — duplication warning) | present (deduped here, optional: true) |

A naive `kubectl apply -f k8s/app.yaml` would have:

1. Stripped `imagePullSecrets` → new pods stuck in `ImagePullBackOff`
2. Reset image to `instant-api:local` → ImagePullBackOff (no such image)
3. Added the `wait-for-platform-db` init container → pod blocks forever
   waiting for an in-cluster service that doesn't exist
4. Dropped ~15 env vars → api boots but immediately fails on missing
   Razorpay annual plans, object-store creds, OAuth client IDs, OTLP
   headers, etc.

That is, three independent failure modes per pod. With `replicas: 2` and
rolling update, that's enough to wipe the api fleet within a minute.

The fix codifies the live state. The placeholder image tag (`:placeholder`)
guarantees that a future naive apply fails loudly (`ErrImagePull`) instead
of silently regressing.

---

## MinIO retirement (2026-05-20) — superseded 2026-08-09

> **SUPERSEDED:** DO Spaces was itself retired on 2026-08-09 with the Azure
> move. **Cloudflare R2 is now the canonical production object store**
> (`OBJECT_STORE_BACKEND=r2`). Azure Blob is deliberately not used: it is not
> S3-compatible, and none of the four coded providers in
> `common/storageprovider/` speak it. R2 is also an *upgrade* in tenant
> isolation — genuine prefix-scoped credentials + STS, versus the synthesised
> prefix isolation over a shared master key that Spaces forced. The section
> below is retained as the history of how MinIO was removed.

The self-hosted MinIO Deployment in `instant-data` was retired in
`chore/retire-self-hosted-minio-2026-05-20` (supersedes the stale PR #4
from 2026-05-11). DO Spaces (`nyc3.digitaloceanspaces.com`, bucket
`instant-shared`) was then the canonical production object-store backend,
selected by `OBJECT_STORE_BACKEND=do-spaces` in `instant-secrets` (and
mirrored to `instant-infra-secrets` for worker + provisioner storage_bytes
scanners).

After this PR merges, run the following on the prod cluster (and on any
local Rancher Desktop clusters that still have the legacy MinIO workload
deployed):

```bash
# 1. Confirm context (do NOT run against the wrong cluster)
kubectl config current-context

# 2. Inventory what's actually there before deleting anything
kubectl get deploy,pvc,svc,job,secret -n instant-data -l app=minio
kubectl get secret -n instant-data minio-secrets 2>/dev/null || echo "no minio-secrets"

# 3. Remove the MinIO workload + storage + services + bootstrap Job + Secret
kubectl delete -n instant-data deploy/minio --ignore-not-found
kubectl delete -n instant-data pvc/minio-data --ignore-not-found
kubectl delete -n instant-data svc/minio svc/minio-external --ignore-not-found
kubectl delete -n instant-data job/minio-bucket-init --ignore-not-found
kubectl delete -n instant-data secret/minio-secrets --ignore-not-found

# 4. Verify nothing left
kubectl get pods -n instant-data | grep -i minio   # should print nothing

# 5. (Optional) If the legacy `s3.instanode.dev` Ingress still points at
#    the minio Service, delete or repoint it to DO Spaces. The Ingress
#    object was untracked in this repo — confirm what's live:
kubectl get ingress -A | grep -i minio

# 6. Sanity-check the storage hot path is unaffected
curl -sS https://api.instanode.dev/healthz | jq .
# /storage/new responses should reference *.digitaloceanspaces.com,
# not minio.instant-data.svc.cluster.local.
```

Rollback: revert the merge commit on master, re-apply the deleted
manifests from history (`git show <revert-sha>~1 -- k8s/data/minio*.yaml |
kubectl apply -f -`), and flip `OBJECT_STORE_BACKEND` back to `minio` in
`instant-secrets`. Storage data isn't lost in either direction — the PVC
was on local-path in Rancher Desktop only; DO Spaces holds the real
production object bytes.

---

## Preview-env subdirectory (Phase 1a, 2026-05-30)

A new `k8s/preview/` subdir landed for the Layer-3 per-PR ephemeral-env
scaffolding. Different apply discipline applies:

- `k8s/preview/00-rbac.yaml`, `02-policies.yaml`, `20-cron-ttl.yaml` are
  the ONLY files in this subdir that the operator applies directly. They
  install: the `preview-system` namespace + ServiceAccount + ClusterRoles
  for the per-PR provisioner, a Kyverno ClusterPolicy that name-prefix-
  guards the SA's namespace creates, and a dry-run TTL CronJob.
- `k8s/preview/10-quota-template.yaml` is a TEMPLATE (not a direct apply
  target). The preview-create GH Actions workflow renders it via
  `envsubst` per-PR. Never `kubectl apply` it directly.
- The preview subdir is INCLUDED in the validate workflow's yamllint +
  kubeconform sweep (no path filter), but the `apply.yml` exclude list
  must skip `k8s/preview/10-quota-template.yaml` (envsubst placeholders
  break literal apply). RBAC + policies + CronJob remain applyable.
- Full operator setup, secret minting, and Phase-1a verification steps
  live in `infra/PREVIEW-ENV-RUNBOOK.md`.

Two operator tasks gate Phase 1b: (a) wildcard A-record
`*.preview.instanode.dev → <load-balancer-IP>` at Cloudflare, (b)
cert-manager `ClusterIssuer/letsencrypt-preview-dns01` (DNS-01 — HTTP-01
doesn't work for wildcards). The runbook has the verification commands.

---

## Worker deploy-status RBAC — jobs/pods/events read grant (2026-06-11)

`k8s/worker-rbac.yaml`'s `instant-worker-deploy-reader` ClusterRole was
extended to grant the worker SA (`instant-worker` in `instant-infra`) the
read-only k8s access its deploy-status reconciler + failure-autopsy path
actually need. Before this, the SA could only `get apps/deployments`, so
the rule-27 silent-build-failure detector logged
`jobs.deploy_status_reconcile.job_query_failed … cannot get resource
"jobs" in API group "batch"` every ~30s and that whole detection path was
**disabled in prod**.

The added verbs map 1:1 to live k8s calls (no over-grant — read-only, no
create/delete/patch/watch):

| apiGroup / resource | verb | worker call (file:line) |
|---|---|---|
| `batch` / `jobs`     | `get`  | `deploy_status_reconcile.go:256` `BatchV1().Jobs(ns).Get` |
| `""` / `pods`        | `list` | `deploy_failure_autopsy.go:208` `CoreV1().Pods(ns).List` |
| `""` / `pods/log`    | `get`  | `deploy_failure_autopsy.go:220,230` `CoreV1().Pods(ns).GetLogs` |
| `""` / `events`      | `list` | `deploy_failure_autopsy.go:215` `CoreV1().Events(ns).List` |

(`apps/deployments get` was already granted and is unchanged.)

This is an RBAC-only change — no Deployment, no secrets, no image tag. It
is safe to `kubectl apply` directly (none of the app.yaml clobber hazards
above apply to a ClusterRole/ClusterRoleBinding/ServiceAccount file).

```bash
# 1. Confirm context
kubectl config current-context        # expect instanode-prod-aks

# 2. Dry-run server-side and read the diff (RBAC verbs only should change)
kubectl apply --dry-run=server -f k8s/worker-rbac.yaml

# 3. Apply
kubectl apply -f k8s/worker-rbac.yaml

# 4. Verify the SA can now reach jobs/pods/events in a deploy namespace.
#    (Use any live instant-deploy-* ns; RBAC is cluster-scoped so the
#    namespace just has to exist. All four must print "yes".)
NS=$(kubectl get ns -o name | grep -m1 'instant-deploy-' | cut -d/ -f2)
kubectl auth can-i get  jobs.batch  --as=system:serviceaccount:instant-infra:instant-worker -n "$NS"
kubectl auth can-i list pods        --as=system:serviceaccount:instant-infra:instant-worker -n "$NS"
kubectl auth can-i get  pods/log    --as=system:serviceaccount:instant-infra:instant-worker -n "$NS"
kubectl auth can-i list events      --as=system:serviceaccount:instant-infra:instant-worker -n "$NS"

# 5. Confirm the error stops within one reconcile tick (~30s). This should
#    print nothing after the apply:
kubectl logs -n instant-infra deploy/instant-worker --since=2m \
  | grep -i 'job_query_failed' || echo "ok — no job_query_failed in last 2m"
```

Rollback: `git revert` the merge commit and re-apply — the verbs are
purely additive, so reverting only narrows the grant back to
`apps/deployments get` (re-disables rule-27 detection, no other effect).

---

## New Relic Prometheus agent — metrics ingestion pipeline (2026-06-11)

`k8s/newrelic-prometheus-agent.yaml` adds the **only metrics scraper** in the
cluster. Before it, prod shipped logs + APM + OTLP traces but **no metrics**,
so ~46 `FROM Metric WHERE metricName LIKE 'instant_%'` NR alerts were inert
(querying an empty `Metric` stream). This manifest deploys the official
newrelic-prometheus-agent (configurator initContainer + Prometheus `--agent`)
in the `newrelic` namespace, scraping the three services' `/metrics` by pod
SD and remote-writing to NR's US Prometheus endpoint.

**This manifest is additive + safe to apply** — it creates net-new objects
(SA, ClusterRole/Binding, ConfigMap, Deployment) in the `newrelic` namespace
and touches **nothing** the api/worker/provisioner Deployments own. It does
NOT have the `app.yaml` clobber hazards (no `:local` image, no
`imagePullSecrets` strip).

**One hazard — the placeholder Secret.** The file ships a Secret template
(`newrelic-prometheus-agent-secrets`) with `CHANGE_ME` for
`NEW_RELIC_LICENSE_KEY` + `METRICS_TOKEN`. Applying that document AFTER you've
created the real secret would clobber it with `CHANGE_ME` and CrashLoop the
agent (`ErrNoLicenseKeyFound`). Create the real secret first (copying the live
NR license key from `instant-secrets` and the `METRICS_TOKEN` inline value off
the api Deployment), then apply everything EXCEPT the Secret. This is the same
`CHANGE_ME`-clobber class as `secrets.yaml` — use the same guardrail discipline
(`scripts/safe-secret-apply.sh`).

Full apply + the post-apply verification gate (the NRQL that proves
`instant_*` series landed and the 46 alerts flipped live), plus the list of
high-value alerts that go armed: **`infra/OBSERVABILITY-PIPELINE.md`**.

Quick apply (real secret first, then the rest):

```bash
# real secret — values copied live, never committed:
kubectl create secret generic newrelic-prometheus-agent-secrets -n newrelic \
  --from-literal=NEW_RELIC_LICENSE_KEY="$(kubectl get secret instant-secrets -n instant -o jsonpath='{.data.NEW_RELIC_LICENSE_KEY}' | base64 -d)" \
  --from-literal=METRICS_TOKEN="$(kubectl get deploy instant-api -n instant -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="METRICS_TOKEN")].value}')" \
  --dry-run=client -o yaml | kubectl apply -f -

# everything else (skip the placeholder Secret in the file):
yq 'select(.kind != "Secret")' k8s/newrelic-prometheus-agent.yaml | kubectl apply -f -

kubectl rollout status deploy/newrelic-prometheus-agent -n newrelic --timeout=120s
```

Verify (NR query builder): `FROM Metric SELECT count(*) WHERE metricName LIKE
'instant_%' SINCE 10 minutes ago` returns non-zero within ~5 min → the 46
`FROM Metric` alerts are live.

Rollback: `kubectl delete -f k8s/newrelic-prometheus-agent.yaml
--ignore-not-found` + delete the secret. No other telemetry stream affected.

---

## AKS clean-cluster bring-up (2026-08-09)

The DigitalOcean → Azure move is a **greenfield rebuild with zero customers**,
which makes it the one chance to get the repo back to being authoritative. The
rule for the Azure cluster is: **everything applied comes from a manifest in
`infra/`; nothing is hand-patched.** Every hand-patch is a future 2026-05-20
near-miss.

### Order (this is what `apply-all.sh` encodes — read it, it is the runbook)

| # | Step | File / command | Why here |
|---|---|---|---|
| 0 | Cluster + node pools + Postgres Flexible Server + static IP | Terraform (`infra/azure/`, owned elsewhere) | — |
| 1 | cert-manager, then ingress-nginx | Helm — `k8s/ingress/README.md` | CRDs must exist before the ClusterIssuer; the LB IP is needed before DNS |
| 2 | DNS A records → LB IP, **DNS-only / grey cloud** | Cloudflare | HTTP-01 cannot validate until the name resolves publicly |
| 3 | Namespaces | `k8s/namespace.yaml` | everything below is namespaced |
| 4 | RBAC | `deploy-rbac.yaml`, `instant-namespace-rbac.yaml`, `worker-rbac.yaml`, `provisioner/rbac.yaml`, `ci-deployer-rbac.yaml` | a Deployment naming a missing ServiceAccount produces pods that are never admitted |
| 5 | Secrets + ConfigMaps + GHCR pull secrets | `secrets.yaml`, `infra-secrets.yaml`, `configmap.yaml`, `migrations-configmap.yaml` | an unresolvable `secretKeyRef` is `CreateContainerConfigError` and does not self-heal without a restart |
| 6 | Data tier | `data/stateful-priority.yaml` → `data/postgres-customers-lockdown.yaml` → the four workloads → `data/networkpolicy.yaml` | PriorityClass is cluster-scoped and must pre-exist; the pg_hba ConfigMap is `subPath`-mounted by postgres-customers, so it must exist before that pod starts |
| 7 | Platform services | `redis.yaml`, `provisioner/`, `app.yaml`, `worker/`, `website.yaml`, `nats-proxy/` | — |
| 8 | Ingress + ClusterIssuer | `k8s/ingress/` | after DNS (step 2), or Let's Encrypt rate limit is burned on failed validations |
| 9 | Metrics pipeline | `newrelic-prometheus-agent.yaml` (real secret FIRST) | without it every `FROM Metric` NR alert is inert |
| 10 | CI | mint `ci-deployer` kubeconfig → `KUBECONFIG_B64` in api/worker/provisioner/infra | then rule 14: `/healthz commit_id` == `git rev-parse --short HEAD` |

### AKS-specific gotchas that bite silently

- **`local-path` does not exist on AKS.** It is the k3s/Rancher-Desktop
  provisioner. A PVC naming it sits `Pending` forever with no error on the pod
  — you only see it in `kubectl describe pvc`. All PVCs in this repo now name
  `managed-csi` explicitly. Never reintroduce `local-path` outside a local-dev
  overlay.
- **NetworkPolicy is accepted but NOT enforced unless a policy engine was
  enabled at cluster creation.** `kubectl get networkpolicy` will happily list
  all four data-tier policies on a cluster that ignores every one of them.
  This is the worst failure mode available: security theatre that reads green.
  Verify, do not assume:
  ```bash
  az aks show -g <rg> -n <cluster> --query networkProfile.networkPolicy -o tsv
  # must print cilium | azure | calico — NOT null
  ```
  It cannot be added later without recreating the cluster (or a constrained
  migration path), so it is a **required Terraform input**.
- **CPU, not memory, is the binding constraint** on the single
  `Standard_B2as_v2`. Measured from the manifests: ~1.65 vCPU of ~1.9
  allocatable requested (~87%) against only ~2.3 GiB of ~5.5 GiB (~41%). A
  Kaniko build that lands on the *system* node overcommits CPU. That is the
  entire reason the Spot pool exists — and it is inert until the api stamps
  the toleration (see `k8s/spot/README.md`). Budget CPU, not RAM.
- **Do not apply `postgres-platform.yaml` on Azure.** It is local-dev only;
  prod platform Postgres is the external Flexible Server. `apply-all.sh` gates
  it behind `LOCAL_DEV=1`.
- **`migrator/` is not bring-up ready** (`instant-migrator:local` +
  `imagePullPolicy: Never`, plus a Temporal dependency this bring-up does not
  install). See the header of `migrator/deployment.yaml`.

### Post-bring-up verification gate

```bash
kubectl get pods -A | grep -Ev 'Running|Completed'   # expect no rows
kubectl get pvc -A                                    # all Bound
kubectl get certificate -n instant                    # Ready=True
curl -sS https://api.instanode.dev/healthz | jq '.commit_id, .migration_version'
curl -sS https://api.instanode.dev/readyz  | jq .
```

Then the two gates that actually prove the platform works (rules 13 + 14) —
neither is satisfied by a log grep:

```bash
# a real database, connected to for real
TOKEN=$(curl -sS -XPOST https://api.instanode.dev/db/new | jq -r .connection_url)
psql "$TOKEN" -c 'select 1;'

# a real deploy, reachable over real TLS (NOT the ingress fake cert)
curl -sSI https://<app-id>.deployment.instanode.dev | head -1
echo | openssl s_client -connect <app-id>.deployment.instanode.dev:443 2>/dev/null \
  | openssl x509 -noout -issuer     # must be Let's Encrypt, NOT
                                    # "Kubernetes Ingress Controller Fake Certificate"
```

That last check is the one that matters most: the live DO cluster was found
serving the ingress-nginx fake certificate, which is exactly the state this
rebuild exists to not recur.

---

## Related files

- `k8s/ingress/README.md` — cert-manager + ingress-nginx install, the
  DNS-before-certificate ordering trap, and the L4 (`tcp:`) port map
- `k8s/spot/README.md` — the Spot node pool scheduling contract and the
  api-side follow-up it depends on
- `README.md` — secrets clobber warning (the same class of bug, but for
  the `secrets.yaml` template)
- `scripts/safe-secret-apply.sh` — runtime guardrail against
  `CHANGE_ME`-clobbering applies of secret YAMLs
- `docs/IMAGE-RETENTION-POLICY.md` — image pinning and retention policy
  referenced by the `instanode.dev/image-pinned` labels
- `apply-all.sh` — the bootstrap script (intended for fresh clusters,
  NOT for in-place prod updates)
- `../OBSERVABILITY-PIPELINE.md` — the New Relic Prometheus agent apply +
  verify runbook (metrics ingestion pipeline; the 46-alert gate)
- `../observability/METRICS-CATALOG.md` — the metric catalog; the pipeline
  above is its hard prerequisite (every `FROM Metric` alert depends on it)
