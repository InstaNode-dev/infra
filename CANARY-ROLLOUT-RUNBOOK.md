# Canary Rollout Runbook — instant-api metric-gated auto-rollback (Wave 7)

> **Status: OPERATOR-APPLY. Nothing in this PR touches prod.** The `infra` repo
> has no auto-apply (CLAUDE.md rule 15). The manifests under `k8s/canary/` and
> this runbook are *ready to migrate*; the live deploy path
> (`api/.github/workflows/deploy.yml` → `kubectl set image deployment/instant-api`)
> is **unchanged** until you deliberately follow §convert and §ci below.
>
> The goal: a bad instant-api image is caught on a **small slice of real
> traffic** and **auto-rolled-back on metric regression**, instead of reaching
> 100% of users and being detected after the fact by an alert.

---

## TL;DR — what this does and the safety story

Today `kubectl set image deployment/instant-api` does a RollingUpdate: the new
image reaches 100% of `api.instanode.dev` traffic within ~minutes, and a
regression is only caught *after* users hit it.

After migration, the deploy becomes an **Argo Rollouts canary**:

```
setWeight 10  →  pause 5m (bake)  →  ANALYSE  →  setWeight 50  →  pause 5m  →  ANALYSE  →  setWeight 100  →  pause 2m  →  promote
                                       │                                          │
                                       └── any metric regresses ──────────────────┴──► ABORT → 100% traffic back to STABLE (auto-rollback)
```

The analysis queries **real prod metrics** (5xx rate, deploy-job failures,
api-up, auth-probe failures). A breach aborts the Rollout and shifts traffic
back to the previous (stable) ReplicaSet — automatically, in the canary window,
before a full rollout.

**Every step of this migration is reversible** (delete the Rollout, scale the
Deployment back up — §rollback-migration). The migration is a deliberate
operator action; the CI deploy path keeps working unchanged until you do §ci.

---

## Files in this change

| File | What it is |
|---|---|
| `k8s/canary/rollout-instant-api.yaml` | `Rollout/instant-api` — canary replacement for `Deployment/instant-api`. Uses `workloadRef` to read the pod template FROM the existing Deployment (zero pod-spec duplication, drop-in parity). |
| `k8s/canary/analysistemplate-instant-api.yaml` | `AnalysisTemplate/instant-api-canary-analysis` — the metric gate (5xx / deploy-job-failures / api-up / auth-probe). Prometheus provider by default; New Relic provider blocks included (commented). |
| `k8s/canary/services-instant-api-canary.yaml` | `instant-api-stable` + `instant-api-canary` Services the controller routes between. The existing `Service/instant-api` and `api` Ingress are untouched. |
| `CANARY-ROLLOUT-RUNBOOK.md` | this file. |

The existing `Deployment/instant-api` (`k8s/app.yaml`) and `Service/instant-api`
are **not modified** by this change.

---

## Pre-flight: is Argo Rollouts installed?

```bash
kubectl get crd rollouts.argoproj.io
```

As of **2026-06-06 this returns `NotFound`** — the controller is NOT installed in
`do-nyc3-instant-prod`, and there is currently **no in-cluster Prometheus**
(live observability is New Relic). Both are operator prerequisites:

- §install — install the Argo Rollouts controller.
- §provider — give the AnalysisTemplate a metrics backend (stand up Prometheus,
  OR switch the template to the New Relic provider).

Do NOT `kubectl apply k8s/canary/*` before both are done — `Rollout` /
`AnalysisTemplate` are CRDs and the apply will fail with "no matches for kind".

---

## §install — install the Argo Rollouts controller

Cluster-scoped, one-time. Pin a version (don't track `stable` blindly).

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f \
  https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/install.yaml

# Wait for the controller:
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=180s
kubectl get crd | grep argoproj.io   # rollouts, analysistemplates, analysisruns, experiments...
```

Install the kubectl plugin (operator convenience — `set image`, `get rollout`,
`promote`, `abort`, `undo`):

```bash
# macOS
brew install argoproj/tap/kubectl-argo-rollouts
# linux
curl -sSLo /usr/local/bin/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/kubectl-argo-rollouts-linux-amd64
chmod +x /usr/local/bin/kubectl-argo-rollouts
kubectl argo rollouts version
```

---

## §provider — give the AnalysisTemplate a metrics backend

The AnalysisTemplate queries metrics. Pick ONE:

### Option A — Prometheus (default in the template)

The template's `prometheus-address` arg defaults to
`http://prometheus-operated.monitoring.svc.cluster.local:9090`. There is no
in-cluster Prometheus today, so you must stand one up that **scrapes
instant-api `/metrics`** with `job="instant-api"` (the analysis queries filter
on that job label, matching `up{job="instant-api"}` already used by the
`APIDown` Prom rule). A minimal kube-prometheus-stack (or the prometheus-operator
already implied by `k8s/prometheus-rules.yaml`, which is a `PrometheusRule` CRD)
works. After it's up, confirm:

```bash
# from a debug pod in the instant ns:
curl -s "http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/query?query=up%7Bjob%3D%22instant-api%22%7D"
```

If your Prometheus Service lives elsewhere, override the arg per-Rollout (no
manifest edit needed):

```bash
# the address is a Rollout arg passed into the analysis; edit the value in
# k8s/canary/analysistemplate-instant-api.yaml (spec.args prometheus-address)
# or pass it through the Rollout's analysis step args.
```

### Option B — New Relic (matches TODAY's prod observability)

Prod ships metrics/transactions to New Relic, and the exact NRQL truth surfaces
already exist (`newrelic/alerts/api-5xx-rate-high.json`, `auth-probe-fail.json`,
`deploy-job-failed-detected.json`). To gate on NR instead of Prometheus:

1. Create the NR provider secret in `instant`:

   ```bash
   kubectl create secret generic newrelic-secret -n instant \
     --from-literal=personal-api-key='<NR_PERSONAL_API_KEY>' \
     --from-literal=account-id='<NR_ACCOUNT_ID>' \
     --from-literal=region='us'
   ```

2. In `k8s/canary/analysistemplate-instant-api.yaml`, for each metric: comment
   out the `provider.prometheus` block and uncomment the `provider.newRelic`
   block beneath it (the NRQL is already written to mirror the live NR alerts).

3. Apply the edited template.

> Either provider yields the same behaviour: a breach fails the AnalysisRun →
> the Rollout aborts → auto-rollback.

---

## §convert — convert the Deployment to a Rollout SAFELY (workloadRef)

The Rollout uses `spec.workloadRef` pointing at the existing
`Deployment/instant-api`, so the **pod template stays in `k8s/app.yaml`** (one
source of truth — env, probes, resources, imagePullSecrets, affinity, preStop,
terminationGracePeriodSeconds all come from the Deployment). This avoids a risky
inline re-copy of the 400-line pod spec.

The cutover, step by step (run during a low-traffic window; have §abort ready):

```bash
# 0. Confirm context + current state.
kubectl config current-context              # MUST be do-nyc3-instant-prod
kubectl get deploy instant-api -n instant   # note replicas (2) + live image
LIVE_IMAGE=$(kubectl get deploy instant-api -n instant \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}')
echo "live image: $LIVE_IMAGE"

# 1. Apply the canary Services (additive — does NOT change Service/instant-api
#    or the api Ingress; pure no-op for live traffic).
kubectl apply -f k8s/canary/services-instant-api-canary.yaml

# 2. Apply the AnalysisTemplate (no-op until referenced by a Rollout).
kubectl apply -f k8s/canary/analysistemplate-instant-api.yaml

# 3. Apply the Rollout. With workloadRef + scaleDown: onsuccess, the controller
#    creates a ReplicaSet from the Deployment's template, brings it healthy,
#    and only THEN scales the Deployment to 0. The very first apply does NOT
#    run the canary steps — it adopts the current state as the stable baseline.
kubectl apply -f k8s/canary/rollout-instant-api.yaml

# 4. Pin the Rollout to the live image so the baseline == what's in prod now
#    (the Rollout template image is inherited from the Deployment via
#    workloadRef, but set it explicitly to be unambiguous):
kubectl argo rollouts set image instant-api -n instant api="$LIVE_IMAGE"

# 5. Watch the Rollout converge to Healthy at 100% stable (no canary on the
#    first roll — it's adopting the baseline).
kubectl argo rollouts get rollout instant-api -n instant --watch
```

**Verify the cutover did not drop traffic** (rule 13/14 live gate):

```bash
kubectl get rollout instant-api -n instant      # STATUS Healthy, replicas 2/2
kubectl get deploy  instant-api -n instant      # READY 0/0 (template-of-record only)
kubectl get endpoints instant-api -n instant    # still has 2 pod IPs (Service unchanged)
curl -fsSL https://api.instanode.dev/healthz | jq .commit_id   # == git rev-parse --short HEAD of the running image
```

If anything looks wrong at any point, go straight to §rollback-migration.

### §traffic — optional: precise nginx traffic-weighting (recommended)

By default (no `trafficRouting`), the canary weight is approximated by **pod
count** — at `setWeight: 10` with 2 replicas the controller rounds up, so the
canary may get ~50% rather than 10%. That is still safe (analysis + abort all
work), just coarser. For PRECISE 10%/50% real-traffic splitting over
`api.instanode.dev`, enable the nginx provider:

1. The cluster runs `ingress-nginx` (`kubectl get pods -n ingress-nginx`) and
   the live Ingress is `api` (`kubectl get ingress -n instant`).
2. In `k8s/canary/rollout-instant-api.yaml`, uncomment the
   `strategy.canary.trafficRouting.nginx` block and set
   `stableIngress: api`.
3. Re-apply the Rollout. The controller clones the `api` Ingress into a canary
   Ingress carrying `nginx.ingress.kubernetes.io/canary-weight: "<N>"` and
   adjusts it as the steps advance.

Defer this if you want the simplest first migration; you can enable it later
with a plain re-apply (no re-cutover).

---

## §ci — switch the api deploy pipeline to the Rollout (do at migration time)

> **Do NOT change `api/.github/workflows/deploy.yml` in THIS infra PR.** Changing
> it before the Rollout exists in the cluster would break every deploy (the new
> command would target a Rollout that isn't there). This step is done by the
> operator, in the `api` repo, AFTER §convert is verified in prod.

The api deploy job currently (verified `api/.github/workflows/deploy.yml`
~L280–307) runs:

```bash
kubectl set image deployment/instant-api api=<IMAGE> -n instant
kubectl rollout status deployment/instant-api -n instant --timeout=300s
# then verifies .spec.template...image == expected and curls /healthz for the SHA
```

After migration, change those two commands to the Rollouts equivalents:

```bash
kubectl argo rollouts set image instant-api api=<IMAGE> -n instant
# Block until the canary fully promotes OR aborts. --timeout must cover the full
# ladder: 5m + 5m + 2m of pauses + analysis + image pull ≈ 20m. On an aborted
# (auto-rolled-back) Rollout this returns NON-ZERO → the deploy job goes RED,
# which is the correct signal: "your image regressed and was rolled back."
kubectl argo rollouts status instant-api -n instant --timeout=1200s
```

- The "Verify rolled-out image tag" step: read the Rollout's stable image
  instead of the Deployment's:
  `kubectl argo rollouts get rollout instant-api -n instant -o json | jq -r '.status.stableRS'`
  (or compare `kubectl get rollout instant-api -n instant -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}'`).
- The "Curl live /healthz and confirm SHA" step is **unchanged** and still
  applies (it's the rule-14 build-SHA gate) — but note that on an aborted
  canary the live SHA will (correctly) still be the OLD stable one, because the
  bad image never reached 100%. Treat a non-zero `rollouts status` as the
  authoritative "deploy failed/rolled-back" signal.
- The deploy job needs the `kubectl-argo-rollouts` plugin on the runner — add an
  install step (the curl one-liner from §install) before the deploy step.
- RBAC: the CI deployer SA needs `rollouts.argoproj.io` verbs. Add a Role/
  binding granting `get,list,watch,update,patch` on `rollouts` (and `get` on
  `analysisruns`) in `instant`, mirroring the existing
  `k8s/ci-deployer-rbac.yaml` Deployment grants. (Operator follow-up manifest.)

Keep the OLD `kubectl set image deployment/...` path working until the Rollout
is live and verified — that is, do §convert FIRST, confirm a real test deploy
through the Rollout, THEN flip the CI commands. There is a window where both
exist; that's fine — the Deployment is scaled to 0 and only the Rollout serves.

---

## §abort — abort / roll back a canary IN PROGRESS (manual)

A canary that the analysis hasn't caught but you don't like:

```bash
# Immediately abort: shifts 100% traffic back to the stable ReplicaSet.
kubectl argo rollouts abort instant-api -n instant

# Inspect what the analysis saw:
kubectl argo rollouts get rollout instant-api -n instant
kubectl get analysisrun -n instant -l rollout=instant-api
kubectl describe analysisrun <name> -n instant   # per-metric measurements + which failed

# Roll back to the previous stable revision explicitly (if already promoted):
kubectl argo rollouts undo instant-api -n instant            # last revision
kubectl argo rollouts undo instant-api -n instant --to-revision=<N>

# Force-promote past a pause (e.g. you've manually verified the canary is good):
kubectl argo rollouts promote instant-api -n instant         # next step
kubectl argo rollouts promote instant-api -n instant --full  # skip all remaining steps
```

The **automatic** abort/rollback (no human) happens when an AnalysisRun breaches
`failureLimit` — that is the whole point of Wave 7; the commands above are the
manual override.

---

## §rollback-migration — back out of Argo Rollouts entirely

If the canary mechanism itself misbehaves (controller bug, analysis flapping,
traffic-routing issue) and you want plain Deployments back — fully reversible:

```bash
# 1. Capture the current good image.
GOOD_IMAGE=$(kubectl get rollout instant-api -n instant \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}')

# 2. Scale the Deployment back up (it was scaled to 0 by workloadRef adoption).
#    It still has the full, correct pod spec from k8s/app.yaml.
kubectl set image deployment/instant-api api="$GOOD_IMAGE" -n instant
kubectl scale deployment/instant-api -n instant --replicas=2
kubectl rollout status deployment/instant-api -n instant --timeout=300s

# 3. Delete the Rollout (this releases the canary ReplicaSets; the Deployment's
#    ReplicaSet now serves Service/instant-api on app=instant-api).
kubectl delete rollout instant-api -n instant

# 4. (Optional) delete the canary scaffolding.
kubectl delete -f k8s/canary/services-instant-api-canary.yaml
kubectl delete -f k8s/canary/analysistemplate-instant-api.yaml

# 5. If you'd flipped CI (§ci), revert api/.github/workflows/deploy.yml back to
#    `kubectl set image deployment/instant-api ...`.

# 6. Verify.
curl -fsSL https://api.instanode.dev/healthz | jq .commit_id
```

Leave the Argo Rollouts controller installed or remove it
(`kubectl delete -n argo-rollouts -f <install.yaml>` + `kubectl delete ns
argo-rollouts`) — it is inert with no Rollout objects.

---

## Observability of the canary itself (rule 25)

The canary is only trustworthy if its own outcomes are visible. The Argo
Rollouts controller exposes its own metrics at the controller's `:8090/metrics`
(`rollout_info{phase}`, `analysis_run_metric_phase`, `rollout_events_total`).
This change ships, for the canary outcome:

- NR alert: `newrelic/alerts/canary-analysis-aborted.json` — page when an
  instant-api canary AnalysisRun reports a failed/error phase (an auto-rollback
  fired — operator should know a deploy was rejected).
- Dashboard tile: "Canary — instant-api rollout phase + analysis outcome" on
  `newrelic/dashboards/instanode-reliability.json`.
- Catalog row in `observability/METRICS-CATALOG.md`.

To feed those, scrape the Argo Rollouts controller `:8090/metrics` from your
Prometheus / NR (add a scrape job for the `argo-rollouts` Service). Until the
controller is installed and scraped, the alert/tile are inert (lazy — no series
yet), exactly like the other lazy metrics in the catalog.

---

## Migration checklist (operator)

- [ ] `kubectl get crd rollouts.argoproj.io` → install controller if NotFound (§install)
- [ ] kubectl-argo-rollouts plugin installed (§install)
- [ ] metrics provider ready — Prometheus scraping `job="instant-api"` OR NR secret (§provider)
- [ ] `kubectl apply -f k8s/canary/services-instant-api-canary.yaml` (additive)
- [ ] `kubectl apply -f k8s/canary/analysistemplate-instant-api.yaml`
- [ ] `kubectl apply -f k8s/canary/rollout-instant-api.yaml` + pin live image (§convert)
- [ ] Rollout Healthy, Deployment 0/0, endpoints intact, /healthz SHA correct (§convert verify)
- [ ] (optional) enable nginx trafficRouting for precise % (§traffic)
- [ ] do a real test deploy THROUGH the Rollout and watch one canary ladder
- [ ] scrape argo-rollouts :8090/metrics → NR/Prom; confirm tile/alert populate (rule 25)
- [ ] flip `api/.github/workflows/deploy.yml` to `kubectl argo rollouts set image` + add plugin install + RBAC (§ci)
- [ ] document the migration date + RTO in this file's drill log below

## Drill log

| Date | Action | Result | Operator |
|---|---|---|---|
| _pending_ | initial migration | — | — |
