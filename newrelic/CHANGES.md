# CHANGES — NR dashboard + alert rollup (2026-05-13)

Pairs the past week of shipped surfaces (PR #15 worker churn job onward) with
NR observability per the user's rule: "if this breaks tomorrow, can I see it
in NR in 5 minutes?"

`apply.sh` iterates every `dashboards/*.json` and `alerts/*.json` file, so the
new files below are picked up automatically — no edits to `apply.sh` or
`terraform/main.tf` required. Validation: `jq empty <file>` passes for all
13 new JSON files (see end of doc).

## New dashboards (5)

| File | Surface | Widgets |
|---|---|---|
| `dashboards/admin-defense.json` | Admin defense-in-depth (PR #66+) | 4 |
| `dashboards/promote-approval.json` | Promote approval flow (PR #65) | 5 |
| `dashboards/billing-dunning.json` | Payment dunning + pricing conversion (PR #66) | 5 |
| `dashboards/resource-lifecycle.json` | Resource pause/resume (migration 027) + deploy lifecycle | 5 |
| `dashboards/ops-rollup.json` | Single-pane on-call ops view across all 5 surfaces | 9 |

Widget total across new dashboards: 28 (task target was ~15 unique widgets;
the 9 rollup billboards reuse data from the surface dashboards but are sized
for at-a-glance). All conform to existing conventions: `accountIds: [0]`
placeholder, `appName LIKE 'instant-api%'`, `service = 'api'` / `'worker'`,
nested `rawConfiguration.nrqlQueries[*].query`.

## New alerts (6)

| File | Surface | Priority |
|---|---|---|
| `alerts/admin-allowlist-breach.json` | admin.access from non-allowlist user | CRITICAL |
| `alerts/admin-probe-404-rate.json` | ADMIN_PATH_PREFIX 404 rate > 50/min for 5m | CRITICAL + WARN |
| `alerts/promote-bypass-detected.json` | promote.approved (non-dev) without prior approval_requested | CRITICAL |
| `alerts/grace-terminated-spike.json` | payment.grace_terminated spike (mass payment-method failure) | CRITICAL + WARN |
| `alerts/paused-resource-stale.json` | Resource paused > 30d (should be terminated) | WARNING |
| `alerts/deploy-failure-rate-high.json` | Deploy failure rate > 30% over 1h | CRITICAL + WARN |
| `alerts/deploy-time-degraded.json` | Median deploy time > 5 min (1h) | CRITICAL + WARN |

That's 7 alert files / 6 task buckets (admin defense-in-depth required two
alerts: allowlist-failure and brute-force probe).

All alerts:
- Match the existing `NrqlConditionStaticInput` shape (NerdGraph-ready).
- Use `type: "NRQL"` discriminator that `apply.sh` strips at apply time
  (see `apply.sh` line 310: `jq 'del(.type)'`).
- Use `appName LIKE 'instant-api%'` / `service = 'api'` / `service = 'worker'`
  to match existing alerts.

## Forward-compat: emit sites not yet shipped

Per the user's "audit kinds map to events even when emit sites don't exist yet"
pattern, several queries reference `audit_log kind` values whose emit sites
are still pending. Listed here for the agent A3 (emit-site) follow-up:

| Audit kind | Emit site | Status |
|---|---|---|
| `admin.access` (fields: `path_suffix`, `user_email`, `allowed`) | admin allowlist middleware | TODO emit-site agent A3 |
| `promote.approval_requested` (fields: `env`, `approval_token`) | `api/internal/handlers/stack.go` | TODO emit-site agent A3 |
| `promote.approved` (fields: `env`, `approval_token`, `approval_latency_seconds`, `bypass_detected`) | same | TODO emit-site agent A3 |
| `promote.rejected` (fields: `env`, `approval_token`) | same | TODO emit-site agent A3 |
| `payment.grace_started` / `grace_reminder` / `grace_recovered` / `grace_terminated` | `api/internal/handlers/billing.go` | TODO emit-site agent A3 |
| `resource.paused` / `resource.resumed` (fields: `resource_id`, `resource_type`) | resource pause handler (migration 027) | TODO emit-site agent A3 |
| `resource.lifecycle_scan` (fields: `paused_age_days`, `resource_id`) | worker resource-lifecycle job | TODO emit-site agent A3 |
| `deploy.created` / `deploy.healthy` / `deploy.failed` (fields: `deploy_id`, `deploy_ready_seconds`) | `api/internal/handlers/deploy.go` | TODO emit-site agent A3 |

Until those emit sites land, the dashboards render but the new widgets are
"No data" — intentional. The structural shape (kind/field names) is the
contract A3 implements against.

## Validation run (2026-05-13)

```
$ for f in newrelic/dashboards/*.json newrelic/alerts/*.json; do jq empty "$f" && echo "ok: $f" || echo "FAIL: $f"; done
ok: newrelic/dashboards/admin-defense.json
ok: newrelic/dashboards/api-overview.json
ok: newrelic/dashboards/billing-dunning.json
ok: newrelic/dashboards/deploy.json
ok: newrelic/dashboards/ops-rollup.json
ok: newrelic/dashboards/promote-approval.json
ok: newrelic/dashboards/provisioning.json
ok: newrelic/dashboards/resource-lifecycle.json
ok: newrelic/dashboards/worker.json
ok: newrelic/alerts/admin-allowlist-breach.json
ok: newrelic/alerts/admin-probe-404-rate.json
ok: newrelic/alerts/api-5xx-rate-high.json
ok: newrelic/alerts/deploy-failure-rate-high.json
ok: newrelic/alerts/deploy-time-degraded.json
ok: newrelic/alerts/error-rate-high.json
ok: newrelic/alerts/grace-terminated-spike.json
ok: newrelic/alerts/nats-down.json
ok: newrelic/alerts/paused-resource-stale.json
ok: newrelic/alerts/promote-bypass-detected.json
ok: newrelic/alerts/p95-latency-high.json
ok: newrelic/alerts/worker-stalled.json
```

`apply.sh --dry-run` should also list every new file. Run before merging:

```bash
cd /tmp/wt-nr-rollup/newrelic
./apply.sh --dry-run
```

## Update to README.md

`newrelic/README.md` "Resources applied" section should append:

- Dashboards: `instant-api — admin defense-in-depth`,
  `instant-api — promote approval flow`,
  `instant-api — billing dunning + pricing`,
  `instant-api — resource pause/resume + deploy lifecycle`,
  `instant-api — ops rollup`.
- Alerts: `instant-api — admin.access from non-allowlist user`,
  `instant-api — ADMIN_PATH_PREFIX 404 rate > 50/min (5m)`,
  `instant-api — promote.approved without prior approval_requested (non-dev)`,
  `instant-api — payment.grace_terminated spike > 5x rolling 7d avg`,
  `instant-api — resource paused > 30d (should be terminated)`,
  `instant-api — deploy failure rate > 30% (1h)`,
  `instant-api — median deploy time > 5 min (build infra degradation)`.

The README update is intentionally left as a manual follow-up because the
existing list is hand-curated.
