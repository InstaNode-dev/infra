# Metrics Catalog — Wave 2 (2026-05-20)

This document enumerates every Prometheus metric registered by `api`, `worker`,
and `provisioner` whose monitoring artifacts (NR alert + Prom rule + dashboard
tile) were added in the 2026-05-20 observability sweep.

It also flags **lazy-emit metrics** — counters/gauges that exist in the
binary but do NOT appear at `/metrics` until the first `.Inc()` or `.Set()`
fires. Operators need this so they don't panic when a fresh deploy looks
"missing" a metric — it's just zero-cardinality until something happens.

## Reading the table

| Column | Meaning |
|---|---|
| **Metric** | Exact name as emitted at `/metrics` |
| **Service** | Which binary registers + emits it |
| **Labels** | The label set the counter/gauge is built with |
| **Emit timing** | `eager` = registered + visible at boot with 0 value, `lazy` = only appears after first observation |
| **NR alert** | Path under `newrelic/alerts/` |
| **Prom rule** | Alert name in `k8s/prometheus-rules.yaml` |
| **Dashboard tile** | Tile title in `newrelic/dashboards/instanode-reliability.json` |

## Catalog

| Metric | Service | Labels | Emit timing | NR alert | Prom rule | Dashboard tile |
|---|---|---|---|---|---|---|
| `instant_propagation_dead_lettered_total` | worker | `reason,kind` | lazy (CounterVec — first Inc creates label series; dead-letter is the unhealthy state) | `propagation-dead-lettered.json` | `PropagationDeadLettered` | "Propagation queue depth + dead-lettered rate", "Propagation retry distribution by kind" |
| `instant_propagation_unknown_kind_total` | worker | `kind` | lazy (only appears on api/worker image skew) | `propagation-unknown-kind.json` | `PropagationUnknownKind` | "Propagation queue depth + dead-lettered rate" |
| `instant_propagation_unexpected_skip_total` | worker | `kind,resource_type,skip_reason` | lazy (post-CHAOS-F1 sentinel — only ticks on the schema/state drift class) | `propagation-unexpected-skip.json` | `PropagationUnexpectedSkip` | "Propagation queue depth + dead-lettered rate" |
| `instant_orphan_sweep_reaped_total` | worker | `reason` | lazy (CounterVec — only when an orphan namespace is actually reaped) | `orphan-sweep-no-db-row.json`, `orphan-sweep-stuck-build-spike.json` | `OrphanSweepNoDBRowReap`, `OrphanSweepStuckBuildSpike` | "Orphan sweep — reaped by reason (24h)" |
| `instant_orphan_sweep_reap_failed_total` | worker | `reason` | lazy | `orphan-sweep-reap-failed.json` | `OrphanSweepReapFailureRate` | "Orphan sweep — reap failures by reason (24h)" |
| `instant_magic_link_email_rate_limited_total` | api | (none) | **eager** (Counter, registered at boot — visible as 0 immediately) | `magic-link-email-rate-limited.json` | `MagicLinkEmailRateLimited` | "Magic-link rate-limited / hour" |
| `brevo_send_errors_total` | worker | `classification,status_code` | lazy (CounterVec — first failure creates label series; `permanent`/`transient` only after the first 401/5xx) | `brevo-send-errors-spike.json` | `BrevoSendErrorsSpike`, `BrevoSendErrorsWarning` | "Brevo send errors by classification (1h)" |
| `brevo_webhook_events_total` | api | `event` | lazy (CounterVec — populates as Brevo posts each event class; `delivered` appears on first successful send, `bounced_hard` only if a bounce happens) | `email-delivery-ratio-low.json` | `BrevoDeliveryRatioLow`, `BrevoDeliveryRatioWarn` | "Brevo delivery ratio (1h sliding)", "Brevo webhook events funnel (24h)" |
| `instant_billing_charge_undeliverable_total` | worker | (none) | **eager** (Counter — visible as 0 at boot; should STAY 0 in steady state) | `billing-charge-undeliverable.json` (log-based) | `BillingChargeUndeliverable` | "Billing charge undeliverable (paid, NOT upgraded) — must be 0" |
| `readyz_check_status` | api + worker + provisioner | `service,check` | **eager** (GaugeVec — set at boot by every /readyz probe; value 1=ok / 0.5=degraded / 0=failed) | `readyz-component-failed.json` | `ReadyzCheckFailed`, `ReadyzCheckDegraded` | "/readyz status (api / worker / provisioner)", "/readyz failed checks", "/readyz degraded checks" |
| `instant_provisioner_circuit_state` | provisioner | `backend` | **eager** (GaugeVec — every breaker initialised at boot at state=0 CLOSED) | `provisioner-circuit-open.json` | `ProvisionerCircuitOpen`, `ProvisionerCircuitHalfOpen` | "Provisioner circuit-breaker state per backend" |
| `email_missing_renderer_total` | worker | `kind` | lazy (CounterVec — any tick is a bug, label series only appears on the broken kind) | `email-missing-renderer.json` | `EmailMissingRenderer` | "Email missing-renderer ticks (any > 0 == P0)" |
| `migration_version`, `migration_count`, `migration_status` (worker `/healthz` JSON fields, NOT Prometheus metrics) | worker | n/a (log-based) | **eager** (read live from `schema_migrations` table by `migrations.Reader`, cached 60s) | `worker-migration-mismatch.json` (log-based) | n/a (log-based) | "Worker /healthz migration_count drift" |

## Lazy-emit gotcha — what operators should expect

For every metric flagged `lazy` above, **a freshly-deployed pod will not show
the label series at `/metrics` until the first event of that class occurs**.
This is normal Prometheus client behaviour (`*Vec` types only materialise label
combinations on demand). The NR alerts handle this correctly via
`fillValue: 0` / `clamp_min(...)` — silent zero is the healthy state.

If a metric is flagged `eager`, the operator can scrape `/metrics` immediately
after pod startup and expect to see the metric at value 0. If a metric is
flagged `lazy` and you can't see it at `/metrics`, that does NOT mean
instrumentation is broken — it means the codepath hasn't been exercised yet
in this pod's lifetime. To verify wiring, trigger the codepath (or look at a
running pod with traffic).

## When to update this catalog

- Adding a metric → add row to the table, ship in the same PR per
  `CLAUDE.md` Rule 25 ("Every new metric ships with its alert + dashboard
  tile in the same PR").
- Removing a metric → keep the row but strike-through and add a "removed in
  <commit>" note so operators understand why an old alert is firing on a
  missing series.
- Renaming a label → update the table AND search-and-replace the NR / Prom
  queries that reference the old label.

## Source files

| File | What it does |
|---|---|
| `api/internal/metrics/metrics.go` | api Counter/Gauge registration |
| `worker/internal/metrics/metrics.go` | worker Counter/Gauge registration |
| `provisioner/internal/circuit/circuit.go` | provisioner circuit-state gauge |
| `worker/main.go` | worker `/healthz` JSON shape (migration fields) |
| `k8s/prometheus-rules.yaml` | PrometheusRule CR alerts |
| `prometheus/alert-rules.yml` | standalone Prometheus file_sd alerts |
| `newrelic/alerts/*.json` | NerdGraph NRQL conditions |
| `newrelic/dashboards/instanode-reliability.json` | Reliability dashboard |
