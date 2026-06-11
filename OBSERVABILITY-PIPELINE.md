# Observability Pipeline — New Relic Prometheus Agent

> **Codified 2026-06-11.** Closes the single biggest observability gap on the
> platform: there was **no metrics ingestion pipeline** in
> `do-nyc3-instant-prod`. Until `k8s/newrelic-prometheus-agent.yaml` is
> applied, **~46 New Relic alert conditions are INERT.**

---

## The gap

The prod cluster shipped three telemetry streams to New Relic:

| Stream | How | Status |
|---|---|---|
| **Logs** | `newrelic-logging` Fluent Bit DaemonSet (ns `newrelic`) → `log-api.newrelic.com` | working |
| **APM** | Go `newrelic` agent in each service | working |
| **Traces** | OTLP exporter → `otlp.nr-data.net:4317` | working |
| **Metrics** | *(nothing)* | **MISSING** |

There was **no Prometheus scraper** pulling the services' `/metrics`. Verify:

```bash
kubectl get pods -A | grep -iE 'prometheus|nri|otel-collector'   # → empty
```

Every service emits a rich `instant_*` / `provisioner_*` Prometheus surface
(circuit-breaker state, conversion funnel, deploy autopsy counters, pg-pool
gauges, billing-reconciler counters, …) on `/metrics`, but nothing scraped it.
So the entire `Metric` event type was empty in NR, and **every alert of the
form `FROM Metric WHERE metricName LIKE 'instant_%'` queried a stream that did
not exist.** 46 alert files under `newrelic/alerts/` are `FROM Metric`:

```bash
grep -rl "FROM Metric" newrelic/alerts/ | wc -l   # → 46
```

Log-based alerts (`FROM Log`) were unaffected — notably `backup-stale-36h` and
`customer-backup-failed` are **log-based** and already fired. (The brief
listed backup-stale as a metric alert; it is not — it reads the backup
CronJob's log line. The genuinely-inert high-value alerts are listed below.)

---

## What this ships

`k8s/newrelic-prometheus-agent.yaml` — the **official newrelic-prometheus-agent**
(newrelic-prometheus-configurator + Prometheus in `--agent` mode) as one
stateless 2-container pod in the `newrelic` namespace:

1. **initContainer `configurator`** (`newrelic/newrelic-prometheus-configurator:2.11.1`)
   — reads the ConfigMap's configurator-schema `config.yaml`, injects the NR
   license key from env, and renders a standard Prometheus scrape config into a
   shared `emptyDir`.
2. **container `prometheus`** (`quay.io/prometheus/prometheus:v3.12.0 --agent`)
   — reads the rendered config, keeps a 30-min WAL only (no PVC), and
   remote-writes to `https://metric-api.newrelic.com/prometheus/v1/write`
   (**US datacenter** — auto-derived from the license-key region; the existing
   logging + go-agents target US: `log-api.newrelic.com`).

**Why this shape** (not nri-bundle, not self-hosted Prometheus): the prod pool
is thin (6×2cpu/4GB). We need exactly the three app `/metrics`, not full
cluster-state monitoring. Agent mode forwards everything to NR — where the
dashboards + alerts already live — so there is no stateful pod to back up.

### The three scrape targets (verified live 2026-06-11)

| Service | Reached via | Port | `/metrics` auth | Sample series |
|---|---|---|---|---|
| `instant-api` | pod SD, ns `instant`, `app=instant-api` | **8080** | **Bearer required** (401 without `METRICS_TOKEN`) | `instant_circuit_breaker_*`, `instant_conversion_funnel_*` |
| `instant-worker` | pod SD, ns `instant-infra`, `app=instant-worker` | **8091** | open (200) | `instant_auth_probe_*`, `instant_billing_reconciler_*` |
| `instant-provisioner` | pod SD, ns `instant-infra`, `app=instant-provisioner` | **8092** | open (200) | `instant_provisioner_circuit_*`, `instant_provisioner_drop_*` |

> **Why Kubernetes pod service discovery, not static Service-DNS targets:**
> the live topology rules out static targets. `instant-worker` has **no
> Service** in prod (it's a background-job Deployment) — `/metrics` on :8091 is
> reachable only by pod IP. `instant-provisioner`'s Service exposes **only
> :50051** (gRPC); the :8092 metrics sidecar is not in the Service. Pod SD
> (role: pod) discovers all three by `app` label and scrapes podIP:port
> directly, surviving pod evictions/reschedules. This is the only deviation
> from the original brief's "static targets" assumption — flagged here for the
> operator.

> **Auth wiring:** the `METRICS_TOKEN` bearer is sent to **all three** targets
> (mounted from the secret as a file, referenced via Prometheus
> `credentials_file`). api **requires** it (401 otherwise); worker +
> provisioner serve a bare `promhttp` handler that **ignores** the header — so
> the config stays correct if they gain gating later. The token is a single
> shared value across all three services today.

---

## Secret prerequisites

The pod references **one secret** in the `newrelic` namespace,
`newrelic-prometheus-agent-secrets`, with two keys. The agent will not start
without both. **The secret holds copies of live values that already exist
elsewhere** — it does NOT introduce new credentials:

| Key | Source of truth (live) | Why a copy is needed |
|---|---|---|
| `NEW_RELIC_LICENSE_KEY` | `instant-secrets` (ns `instant`) **and** `instant-infra-secrets` (ns `instant-infra`) — same INGEST key the logging DaemonSet + go-agents use | k8s secrets are namespace-scoped; the agent runs in `newrelic`, so it needs a copy there |
| `METRICS_TOKEN` | an **inline `value:` env** on all three Deployments (NOT a k8s secret key today) — same token on api/worker/provisioner | the scraper needs the bearer to read api `/metrics` |

> The repo `k8s/newrelic-prometheus-agent.yaml` ships a **Secret template with
> `CHANGE_ME` placeholders** (repo convention). The operator populates the real
> values out-of-band (commands below) — no real secret value is ever committed.

---

## Operator apply + verify runbook

This repo has **no auto-apply** (CLAUDE.md rule 15). Apply is a deliberate,
human-driven step. Run against the prod context.

### 0. Confirm context + the gap

```bash
kubectl config current-context                          # → do-nyc3-instant-prod
kubectl get pods -A | grep -iE 'prometheus|nri|otel-collector'   # → empty (gap present)
```

### 1. Create the agent secret (real values, never committed)

```bash
# NR license key — copy from the existing instant-secrets:
NR_LICENSE=$(kubectl get secret instant-secrets -n instant \
  -o jsonpath='{.data.NEW_RELIC_LICENSE_KEY}' | base64 -d)

# METRICS_TOKEN — copy the inline value off the api Deployment:
METRICS_TOKEN=$(kubectl get deploy instant-api -n instant \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="METRICS_TOKEN")].value}')

# Sanity-check both are non-empty before creating the secret:
[ -n "$NR_LICENSE" ] && [ -n "$METRICS_TOKEN" ] && echo "both present" || echo "MISSING — STOP"

kubectl create secret generic newrelic-prometheus-agent-secrets \
  -n newrelic \
  --from-literal=NEW_RELIC_LICENSE_KEY="$NR_LICENSE" \
  --from-literal=METRICS_TOKEN="$METRICS_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

> Do **not** `kubectl apply` the `Secret` document inside
> `k8s/newrelic-prometheus-agent.yaml` directly — it carries `CHANGE_ME`
> placeholders and would clobber the real values. Use the `create secret`
> command above; it is the source of truth for the live secret. (When applying
> the full manifest in step 3, the placeholder Secret is the only object you
> skip — see the note there.)

### 2. Dry-run the manifest (must pass — same checks as CI `validate.yml`)

```bash
kubectl apply --dry-run=client -f k8s/newrelic-prometheus-agent.yaml
# → serviceaccount / clusterrole / clusterrolebinding / configmap /
#   deployment / secret  ... all "created (dry run)"

# Optional, exactly what CI runs:
kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.31.0 \
  k8s/newrelic-prometheus-agent.yaml
```

### 3. Apply (everything EXCEPT the placeholder Secret)

The real secret was created in step 1. Apply the rest:

```bash
# Apply the SA, RBAC, ConfigMap, and Deployment. The placeholder Secret in the
# file is the only object to leave out — step 1 owns the live secret.
kubectl apply -f k8s/newrelic-prometheus-agent.yaml \
  --prune=false 2>/dev/null

# If you prefer to never even submit the CHANGE_ME Secret, split it out:
#   yq 'select(.kind != "Secret")' k8s/newrelic-prometheus-agent.yaml | kubectl apply -f -
```

> The placeholder Secret has `stringData` with `CHANGE_ME`. If applied AFTER
> step 1 it WOULD overwrite the real key with `CHANGE_ME`. Either skip it (the
> `yq` split above) or re-run step 1 immediately after. The pod will
> CrashLoop / fail the configurator (`ErrNoLicenseKeyFound`) if the secret
> holds `CHANGE_ME`.

### 4. Confirm the pod is up + scraping

```bash
kubectl rollout status deploy/newrelic-prometheus-agent -n newrelic --timeout=120s
kubectl get pods -n newrelic -l app=newrelic-prometheus-agent

# Confirm all three targets are UP (port-forward the agent and read its
# Prometheus targets API):
kubectl port-forward -n newrelic deploy/newrelic-prometheus-agent 19090:9090 &
sleep 3
curl -s http://localhost:19090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels'].get('job'), t['health']) \
      for t in json.load(sys.stdin)['data']['activeTargets']]"
# Expect: instant-api up / instant-worker up / instant-provisioner up
kill %1
```

### 5. **Verification gate — the inert alerts go live**

Within **~5 minutes** of the pod running, `instant_*` series appear in New
Relic. Run in the NR query builder (account = the prod ingest account):

```sql
FROM Metric SELECT count(*) WHERE metricName LIKE 'instant_%' SINCE 10 minutes ago
```

A non-zero result is the proof. Spot-check a high-value one:

```sql
FROM Metric SELECT latest(instant_provisioner_circuit_state)
  WHERE metricName = 'instant_provisioner_circuit_state' FACET backend SINCE 10 minutes ago
```

Once `Metric` is populated, **all 46 `FROM Metric` alert conditions become
live** (they were querying an empty stream before). The highest-value ones
that flip from inert to armed:

| Alert (`newrelic/alerts/…`) | Catches |
|---|---|
| `razorpay-webhook-sig-fail.json` | forged billing webhook / `RAZORPAY_WEBHOOK_SECRET` mismatch |
| `deploy-job-failed-detected.json` | silent build-Job failure (rule 27 triad, Bug A) |
| `deploy-runtime-failed-detected.json` | silent runtime start-failure (twin of rule 27) |
| `provisioner-circuit-open.json` | a provisioning backend down, fail-fast active |
| `pg-pool-saturation.json` | Postgres connection brownout (pool > 80%) |
| `email-delivery-ratio-low.json` | Brevo delivery ratio < 95% (the rule-12 truth surface) |
| `auth-probe-fail.json` | synthetic login loop broken in prod (AUTH-004) |
| `payment-probe-fail.json` | Layer-3 money heartbeat — paid revenue path broken |
| `redis-maxmemory-regrade-failed.json` | quota not enforced on regrade |

> **Note on backup durability alerting:** `backup-stale-36h.json` and
> `customer-backup-failed.json` are **`FROM Log`** alerts and already fired
> before this pipeline — they read the backup CronJob's log lines, not a
> metric. This pipeline does not change them. (Corrected from the original
> brief, which grouped backup-stale with the metric alerts.)

---

## Rollback

```bash
kubectl delete -f k8s/newrelic-prometheus-agent.yaml --ignore-not-found
kubectl delete secret newrelic-prometheus-agent-secrets -n newrelic --ignore-not-found
```

Removing the agent stops metric ingestion; the `FROM Metric` alerts go inert
again (no data → no violation). No other telemetry stream is affected.

---

## Open items for operator confirmation

- **NR datacenter region:** assumed **US** (the logging DaemonSet targets
  `log-api.newrelic.com` and the go-agents target `otlp.nr-data.net` — both
  US). The configurator auto-selects US vs EU from the license-key prefix, so
  the US `metric-api.newrelic.com` endpoint is correct for our key. If the
  account is later confirmed EU, no manifest change is needed (the configurator
  re-derives the endpoint from the key).
- **provisioner :8092 not a declared containerPort.** The live provisioner
  Deployment listens on :8092 inside the pod but does not declare it as a
  `containerPort`. Pod-SD scraping podIP:8092 works regardless (verified live).
  Declaring it (and a metrics Service) is a nice-to-have cleanup in
  `k8s/provisioner/deployment.yaml`, not a prerequisite for this pipeline.
