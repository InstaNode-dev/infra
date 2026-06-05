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
| `instant_email_failover_total` | worker | `outcome` | lazy (CounterVec — ONLY emits when `EMAIL_PROVIDER_FALLBACK` is configured; inert single-provider default never observes a label. `primary_ok` on first send, `fallback_ok`/`all_failed` only on a real primary failure) | `email-failover-engaged.json`, `email-failover-all-failed.json` | `EmailFailoverEngaged` (P1), `EmailFailoverAllFailed` (P0) | "Email failover outcomes (1h)" |
| `migration_version`, `migration_count`, `migration_status` (worker `/healthz` JSON fields, NOT Prometheus metrics) | worker | n/a (log-based) | **eager** (read live from `schema_migrations` table by `migrations.Reader`, cached 60s) | `worker-migration-mismatch.json` (log-based) | n/a (log-based) | "Worker /healthz migration_count drift" |
| `instant_idempotency_replay_refunded_total` | api | `route` | lazy (CounterVec — first cache HIT on each route materialises the label series; a fresh deploy with no retries reports nothing until the first agent retries with the same `Idempotency-Key`) | `idempotency-replay-refund-spike.json` | `IdempotencyReplayRefundSpike` | "Idempotency replay refunds by route (1h) — FINDING API-1" |
| `instant_auth_probe_outcome_total` | worker | `leg,result` | lazy (CounterVec — `pass`/`degraded` materialise on the first happy tick; `fail` only appears after a real regression. AUTH-004 synthetic prober: every 5 min the worker drives /auth/email/start + /auth/exchange CORS contract + /auth/me bearer against prod) | `auth-probe-fail.json` | `AuthProbeFail` | "AUTH-004 synthetic prober — outcomes per leg (1h)", "AUTH-004 synthetic prober — fails (last 1h, must be 0)" |
| `instant_auth_probe_latency_seconds` | worker | `leg` | lazy (HistogramVec — observation only on a real HTTP response; DNS/TCP errors omit the observation so the histogram isn't polluted with 0s timeouts) | (covered by `auth-probe-fail.json`) | (covered by `AuthProbeFail`) | "AUTH-004 synthetic prober — P95 latency per leg (1h)" |
| `instant_deploy_probe_outcome_total` | worker | `leg,result` | lazy (CounterVec — `pass`/`degraded` materialise on the first happy tick; `fail` only appears after a real regression. Hourly deploy prober: every 60 min the worker drives /deploy/new + status-poll until healthy + public-host GET against prod. Closes the 2026-05-30 stuck-build gap that hid a broken deploy pipeline for ~30 min) | `deploy-probe-fail.json` | `DeployProbeFail` | "Hourly deploy prober — outcomes per leg (6h)", "Hourly deploy prober — fails (last 6h, must be 0)" |
| `instant_deploy_probe_latency_seconds` | worker | `leg` | lazy (HistogramVec — observation only on a real HTTP response or successful status flip; DNS/TCP errors omit the observation. Buckets span the per-leg budgets up to the 120s cold-cluster Kaniko ceiling) | (covered by `deploy-probe-fail.json`) | (covered by `DeployProbeFail`) | "Hourly deploy prober — P95 latency per leg (6h)" |
| `instant_tier_upgrade_ttl_promote_total` | api | `outcome` | lazy (CounterVec — outcome label series materialise on first paid-tier upgrade after deploy; `error` should stay absent in a healthy deploy. P1 fix 2026-05-31 — emits from billing.handleSubscriptionCharged → PromoteDeploymentTTLsForTeam) | `tier-upgrade-ttl-promote-failed.json` | `TierUpgradeTTLPromoteFailed` | "Tier-upgrade TTL promote outcomes (24h) — error must be 0" |
| `instant_customer_backup_failed_total` | worker | `reason` | lazy (CounterVec — `reason` series materialise on first failure: auth/decrypt/config/dump/upload. `auth`=credential drift, SLA breach, won't self-heal → CRITICAL; others WARNING. Added 2026-06-03 after a failed backup paged no one — stale=36h, no-followup=stuck-only) | `customer-backup-failed.json` | `CustomerBackupCredentialFailure`, `CustomerBackupFailures` | "Customer backup failures by reason (24h)" |
| `instant_customer_backup_succeeded_total` | worker | (none) | **eager** (Counter — visible as 0 at boot; paired with `_failed_total` for the success-ratio billboard) | (ratio feeds the dashboard; no standalone alert) | (none — denominator only) | "Backup success rate (last 24h, all teams)" |
| `instant_github_webhook_received_total` | api | `event,result` | lazy (CounterVec — label series only materialise on first delivery of each `{event,result}` combination; `bad_signature` only appears after the first malformed/spoofed delivery; `ok` appears after the first valid push. event ∈ {push,installation,...}; result ∈ {ok,bad_signature,replay,no_match,error}. P4 GitHub App push-to-deploy, pre-staged 2026-06-03) | `github-webhook-bad-signature.json` | `GitHubWebhookBadSignatureSpike` | "GitHub webhook — received by event+result (6h)", "GitHub webhook — bad_signature count (1h, must be 0 in steady state)" |
| `instant_github_pushdeploy_total` | api | `result` | lazy (CounterVec — label series materialise on first push matching an installation+connection; `error` only appears after the first enqueue failure. result ∈ {enqueued,rate_limited,no_connection,error}. Enqueued = happy path; rate_limited = expected; no_connection = repo not linked to a stack; error = broken pipeline. P4 GitHub App push-to-deploy, pre-staged 2026-06-03) | `github-pushdeploy-error.json` | `GitHubPushDeployError` | "GitHub push-to-deploy — result breakdown (6h)", "GitHub push-to-deploy — enqueued vs errors (6h)" |
| `instant_github_app_token_mint_total` | api | `result` | lazy (CounterVec — label series materialise on first installation auth attempt; `cache_hit` only appears after the first token cache hit. result ∈ {minted,cache_hit,error}. minted=fresh JWT from GitHub API; cache_hit=reused unexpired token (reduces GitHub API calls); error=private key missing/malformed or GitHub API down. P4 GitHub App push-to-deploy, pre-staged 2026-06-03) | (no standalone alert; error visible in `github-pushdeploy-error.json` cascade) | (no standalone rule; covered by `GitHubPushDeployError` cascade) | "GitHub App token mint — result breakdown (6h)" |
| `instant_entitlement_drift_detected_total` | worker | (none) | **eager** (Counter — visible as 0 at boot; counts Postgres resources found drifted below their team's plan tier per sweep) | `entitlement-drift-outpacing-regrade.json` (paired with `_regraded_total`) | `EntitlementDriftOutpacingRegrade` (instant-worker-entitlement-drift group) | "Entitlement drift detected vs regraded (6h)", "Entitlement drift backlog (1h, detected - regraded; must be 0)" |
| `instant_entitlement_regraded_total` | worker | (none) | **eager** (Counter — visible as 0 at boot; counts resources successfully re-graded to the entitled cap, provisioner applied=true) | `entitlement-drift-outpacing-regrade.json` (denominator: detected - regraded) | `EntitlementDriftOutpacingRegrade` (instant-worker-entitlement-drift group) | "Entitlement drift detected vs regraded (6h)", "Entitlement drift backlog (1h, detected - regraded; must be 0)" |
| `instant_deploy_job_failed_detected_total` | worker | `reason` | lazy (CounterVec — first observation is a real Kaniko build-Job Failed detection; reason ∈ {DeadlineExceeded, BackoffLimitExceeded, ...}. metrics_test forces a label so the metric registers at boot. Silent-deploy-failure fix, CLAUDE.md rule 27 / 2026-05-30 incident) | `deploy-job-failed-detected.json` | `DeployJobFailedDetected` (instant-worker-deploy-job-failed group) | "Deploy build-Job failures by reason (6h)", "Deploy build-Job failures (1h, detected; must be 0 in steady state)" |
| `instant_billing_reconciler_gap_detected_total` | worker | `direction` | lazy (CounterVec — direction ∈ {upgrade, downgrade}; series materialise on the first detected mismatch between Razorpay subscription state and teams.plan_tier. The primary signal for a dropped Razorpay webhook) | `billing-reconciler-gap-detected.json` | `BillingReconcilerGapDetected` (instant-worker-billing-gap group) | "Billing reconciler gap detected by direction (6h)" |
| `instant_pg_pool_in_use` / `instant_pg_pool_max` | api + worker + provisioner | `pool` | **eager** (GaugeVec — sampled every 5s by each process's pool-stats exporter; `pool` label e.g. `platform_db`. Saturation ratio = in_use/max. Wave-3 chaos-verify 2026-05-21) | `pg-pool-saturation.json` | `PGPoolSaturation` (instant-pg-pool group) | "Postgres pool saturation ratio by service+pool (3h) — alert > 0.8", "Postgres pool peak saturation (1h, in_use/max) — alert > 0.8" |
| `instant_redis_maxmemory_failed_total` | worker | (none) | **eager** (Counter — visible as 0 at boot; increments when the A4 reconciler's provisioner RegradeResource gRPC call fails. Distinct from `_skipped_total` soft-skips. Quota not enforced on dedicated Redis pods when > 0) | `redis-maxmemory-regrade-failed.json` | `RedisMaxmemoryRegradeFailed` (instant-worker-redis-maxmemory group) | "Redis maxmemory regrade failures (6h) — quota not enforced when > 0" |
| `instant_expire_deprovision_failed_total` | worker | (none) | **eager** (Counter — visible as 0 at boot; increments when the 24h-TTL reaper's provisioner DeprovisionResource call errors. Per MR-P0-1a the row is left reapable for retry — orphan infra accumulating when sustained > 0) | `expire-deprovision-failed.json` | `ExpireDeprovisionFailed` (instant-worker-expire-deprovision group) | "Expiry deprovision failures (6h) — orphan infra accumulating when > 0" |
| `instant_worker_goroutine_panics_recovered_total` | worker | `site` | lazy (CounterVec — `site` series only materialises on a real recovered panic; any tick is a code defect. Counterpart api metric is `instant_goroutine_panics_total{task}`) | `goroutine-panics-recovered.json` | `GoroutinePanicsRecovered` (instant-code-defects group; expr sums the api + worker counters) | "Goroutine panics recovered (1h, safego; must be 0)", "Goroutine panics recovered by site (6h)" |
| `instant_pool_reap_total` | provisioner | `resource_type,status,outcome` | lazy (CounterVec — declared via promauto in `provisioner/internal/pool/metrics.go`; label series materialise only when the maintenance-loop reaper acts on a `status="failed"` pool_item. `outcome` ∈ {`reaped` = backing infra deprovisioned + row deleted, `deprovision_err` = backend Deprovision errored (row left for next tick), `delete_err` = Deprovision ok but row DELETE failed}. A sustained `deprovision_err`/`delete_err` rate means the reaper is wedged and 'failed' pool infra is accumulating. Hot-pool reaper, sweep #8 / PR #44) | `pool-reap-errors.json` | `PoolReapErrors` (instant-provisioner-pool-reaper group) | "Pool reaper — actions by status/outcome (24h)" |
| `instant_pool_stuck_assigned` | provisioner | `resource_type` | lazy (GaugeVec — declared via promauto in `provisioner/internal/pool/metrics.go`; per-`resource_type` series materialises only when `reportStuckAssigned` first finds an `assigned` pool_item older than the 30m grace. Deliberately NOT auto-reaped — the provisioner cannot distinguish a crashed-claim orphan from a live api binding (truehomie-db DROP incident class), so a sustained non-zero is an OPERATOR signal for a manual resources-table anti-join, not an auto-reap trigger. Hot-pool reaper, sweep #8 / PR #44) | `pool-stuck-assigned.json` | `PoolStuckAssigned` (instant-provisioner-pool-reaper group) | "Pool items stuck 'assigned' past 30m — leaked shared infra (must be 0)" |
| `instant_flow_test_total` | worker | `flow,actor,tier,layer,result` | lazy (CounterVec — INERT until `FLOW_SYNTHETIC_ENABLED=true`; once on, `pass`/`degraded` materialise on the first happy tick and `fail` only on a real regression. Continuous-monitoring synthetic flow runner (`flow_synthetic.go`): every 5 min runs the P0 flow matrix (healthz / auth_me / provision→reap) against prod. The matrix dashboard FACETs this into the green/red grid, one cell per flow×actor) | `flow-test-p0-fail.json`, `flow-test-silent-death.json` | `FlowTestP0Fail`, `FlowTestSilentDeath` (instant-worker-flow-synthetic group) | "Flow matrix — latest result per flow×actor (grid)", "Flow matrix — fails by flow (1h, must be 0)" |
| `instant_flow_test_latency_seconds` | worker | `flow,actor,tier,layer` | lazy (HistogramVec — observation only on a real HTTP response; DNS/TCP errors omit it so the histogram isn't polluted with 0s timeouts. INERT until `FLOW_SYNTHETIC_ENABLED=true`) | `flow-test-latency-regression.json` | `FlowTestLatencyRegression` (instant-worker-flow-synthetic group) | "Flow matrix — P95 latency per flow (6h)" |
| `instant_flow_synthetic_reaped_total` | worker | `flow,outcome` | lazy (CounterVec — rule-24 cleanup ledger; `reaped` materialises on the first provision→reap tick, `leaked` ONLY on a failed reap (a real DO/k8s resource leak — must stay 0), `skip` when a flow created nothing. INERT until `FLOW_SYNTHETIC_ENABLED=true`) | `flow-synthetic-leak.json` | `FlowSyntheticLeak` (instant-worker-flow-synthetic group) | "Flow synthetic — leaked reaps (1h, must be 0)" |

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
