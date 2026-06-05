# Synthetic prod monitoring — operator enable runbook

> **What this turns on:** continuous synthetic monitoring of prod's money/value
> user journeys, every 5 minutes, reading **truth surfaces** (CLAUDE.md rule 12),
> with results pushed to New Relic so any failure is studyable from the NR
> dashboards. The application code is fully shipped and **flag-gated OFF by
> default** (the DoD habit) — enabling is a deliberate operator action because
> the synthetic runner provisions real resources (and reaps them) and mints a
> durable synthetic team in the platform DB.

This is the "turn on continuous prod monitoring" runbook referenced by
`worker/internal/jobs/flow_synthetic.go`, `flow_synthetic_money.go`,
`auth_probe.go`, and the `flow-test-*` / `auth-probe-fail` NR alerts.

---

## What runs when enabled

The worker's `flow_synthetic` River periodic job ticks **every 5 min** and runs
two flow matrices against prod (`https://api.instanode.dev` by default), each leg
tagged `(flow, actor, tier, layer, result)` and `cohort=synthetic`:

**P0 read/provision matrix** (`flow_synthetic.go`):
- `healthz` — anon `GET /healthz`, assert 200 + commit_id.
- `auth_me` — authenticated `GET /auth/me`, assert 200 + email.
- `provision_reap` — `POST /db/new` → `DELETE /api/v1/resources/:id` (rule-24 reap).

**Money/value-journey matrix** (`flow_synthetic_money.go` — Wave 5), each a truth surface:
- `claim` — `GET /claim/preview` with an invalid token, assert the 400
  `invalid_token` contract (the anon→claimed funnel step, single-use-preserving).
- `deploy_status` — `POST /deploy/new`, assert the tier-gate 402 wall on a
  no-headroom tier (or 201 + reap on a headroom tier).
- `checkout` — `POST /api/v1/billing/checkout`, assert non-5xx reachability
  (contract-only; Razorpay live recurring is operator-blocked).
- `magic_link` — `POST /auth/email/start` (202) **then read the
  `forwarder_sent.classification` ledger** (rule 12 — a `rejected` classification,
  today's Brevo-unvalidated-sender reality, FAILS the leg; the 202 alone does NOT
  prove delivery).

Every result lands as:
- a Prometheus counter `instant_flow_test_total{flow,actor,tier,layer,result}`
  (+ `instant_flow_test_latency_seconds`, `instant_flow_synthetic_reaped_total`),
- an `InstantFlowTest` NR custom event (`cohort=synthetic`, with `commitId` so a
  red names the deploy — rule 14/15),
- on fail: an `audit_log` row (`kind=flow_test_failed`, `actor=system:flow_synthetic`)
  + a structured `slog` ERROR line (the NR fallback if /metrics scrape is down).

The synthetic team carries `is_test_cohort=true`, so every team-iterating
background job no-ops for it and it is excluded from the funnel/billing/business
dashboards (`WHERE cohort != 'synthetic'`).

---

## Enable steps (operator — you cannot set prod env from CI)

1. **Set the master flag + the JWT secret on the worker deployment.** The runner
   mints its session JWT locally with the **same** `JWT_SECRET` the api verifies
   against (Brevo-free auth), so that secret must be present on the worker:

   ```bash
   # JWT_SECRET is already in instant-secrets (the api uses it). Confirm the
   # worker pulls it; if not, add the same value to the worker's env.
   kubectl set env -n instant-infra deploy/instant-worker \
     FLOW_SYNTHETIC_ENABLED=true \
     JWT_SECRET="$(kubectl get secret -n instant instant-secrets -o jsonpath='{.data.JWT_SECRET}' | base64 -d)"
   ```

2. **(Optional) Enable the AUTH-004 synthetic login prober's authed leg.** The
   `auth_probe` job (separate from flow_synthetic) degrades its `/auth/me` leg
   until a bearer token is configured:

   ```bash
   kubectl set env -n instant-infra deploy/instant-worker \
     AUTH_PROBE_BEARER_TOKEN="<a long-lived synthetic session JWT or PAT>"
   ```

3. **(Optional) Tune cadence / scope** — all default sensibly:
   - `FLOW_SYNTHETIC_BASE_URL` — override the probed api host (default
     `https://api.instanode.dev`); a staging worker can probe its own cluster.
   - `FLOW_SYNTHETIC_TIER` — seeded synthetic-team tier (default `free`; a
     headroom tier like `hobby` makes the `deploy_status` leg create+reap a real
     app each tick — only do this on staging, it churns postgres-customers).
   - `FLOW_SYNTHETIC_DISABLED` — comma list of per-flow kill switches, e.g.
     `FLOW_SYNTHETIC_DISABLED=deploy_status,provision_reap` to silence one
     flapping leg without killing the suite.
   - `FLOW_SYNTHETIC_EMAIL` — synthetic primary-user email (default
     `synthetic+flowtest@instanode.dev`).

4. **Roll + verify the flag took:**

   ```bash
   kubectl rollout status -n instant-infra deploy/instant-worker
   # within ~5 min, confirm events are landing in NR:
   #   NRQL:  SELECT count(*) FROM InstantFlowTest WHERE cohort='synthetic' SINCE 10 minutes ago FACET flow
   # and the matrix metric:
   #   NRQL:  SELECT sum(instant_flow_test_total) FROM Metric FACET flow, result SINCE 10 minutes ago
   ```

## Disable (instant kill)

```bash
kubectl set env -n instant-infra deploy/instant-worker FLOW_SYNTHETIC_ENABLED-
# (the trailing '-' unsets it; the whole layer goes inert on the next tick)
```

---

## Alerts that light up once enabled

| Alert | Severity | Fires on |
|---|---|---|
| `newrelic/alerts/flow-test-p0-fail.json` | P0 | any P0 flow (healthz/auth_me/provision_reap) fail over 10m |
| `newrelic/alerts/flow-test-money-fail.json` | P1 | any money flow (claim/deploy_status/checkout/magic_link) fail over 10m |
| `newrelic/alerts/flow-test-latency-regression.json` | P2 | a flow P95 latency > 5s over 30m |
| `newrelic/alerts/flow-test-silent-death.json` | P1 | the runner stops emitting for 15m (monitoring blind spot) |
| `newrelic/alerts/flow-synthetic-leak.json` | P2 | a reap failed → a real resource leaked (must stay 0) |
| `newrelic/alerts/auth-probe-fail.json` | P0 | the AUTH-004 login-loop prober fails over 10m |

Dashboard: the flow matrix grid lives on
`newrelic/dashboards/instanode-reliability.json`; the CI-side health (separate)
is `newrelic/dashboards/instanode-ci-health.json`.

> **`flow-test-silent-death` caveat:** it is a loss-of-signal alert — only
> meaningful once the flag is ON. Before enablement, no `InstantFlowTest` events
> is the expected state, so leave that one condition disabled on clusters where
> `FLOW_SYNTHETIC_ENABLED` is not yet set (or accept that it'll be "open" until
> the first tick).

## Notes

- **Why a real DB every tick is acceptable:** the `provision_reap` leg creates a
  10MB free-tier Postgres and deletes it via the real delete path each tick; the
  reaper backstop sweeps any orphan older than 30m. Monitor `pg-pool-saturation`
  after enabling (plan §6).
- **The synthetic team is durable + idempotent** (stable UUIDv5 ids,
  `INSERT … ON CONFLICT DO NOTHING`); it is seeded only when the master flag is
  on, so a worker without `FLOW_SYNTHETIC_ENABLED` never writes a synthetic team.
- **Team-tier flows stay OFF** (`FLOW_SYNTHETIC_TEAM_ENABLED`) until Team is GA
  (`project_team_plan_not_rolled_out_no_payment.md`).
