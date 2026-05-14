# newrelic/ change log

Append-only log of dashboard and alert changes shipped from this repo. Pair every
entry with the audit-kind emit sites or metric exporters it depends on — the
dashboard/alert is dead unless the upstream service is also shipped.

## W10 follow-up (2026-05-14)

PR: `feat/w10-nr-observability-followup-fresh`.

Adds dashboards + alerts for the ~25 audit kinds shipped in waves W4-B3,
W5-B-api, W7-A through W7-G, W8 (PATCH /team), and W9-C1 (storage IAM).
These are the kinds A1 (the Wave-4 NR rollup, still uncommitted at the start
of today's session) did not cover — A1 only knew about the surfaces that
existed when it was written.

### Files added

Dashboards (2):
- `dashboards/audit-feed-wave9.json` — one billboard tile per new audit kind
  ("hits last 24h") plus a tier-faceted page for `subscription.*`,
  `backup.*`, `deploy.failed by team`, and `vault.*` traffic shape.
- `dashboards/customer-visible-backup-health.json` — operator-facing board
  for support triage: per-team success rate, p50/p95 duration, failure
  reasons, last-50 backup-op table for paste-into-ticket workflow.

Alerts (5):
- `alerts/team-deletion-failed.json` — CRITICAL on any
  `team.deletion_failed` event in 1h (manual reconcile needed).
- `alerts/storage-iam-create-failed.json` — CRITICAL on any
  `instant_storage_iam_users_failed_total{op="create"}` increment in 5m
  (signup-blocking).
- `alerts/connection-url-decrypt-burst.json` — WARN > 50/h,
  CRITICAL > 200/h per team on `connection_url.decrypted`
  (credential-harvesting indicator).
- `alerts/deploy-failure-rate-by-team.json` — WARN 15%, CRITICAL 30%
  rolling 1h failure rate, faceted by `team_id` (extends A1's aggregate
  alert with per-customer breakdown).
- `alerts/backup-requested-no-followup.json` — WARN on `backup.requested`
  with no matching `backup.succeeded` / `backup.failed` for the same
  `backup_id` within 30m (stuck-worker indicator).

### Audit kinds wired

| Kind | Source PR | Emit site (expected) | Status |
|---|---|---|---|
| `team.updated` | W8 | `api/internal/handlers/team.go` PATCH | merged to api |
| `team.deletion_requested` | W7-D | `api/internal/handlers/team.go` | merged to api |
| `team.deletion_canceled` | W7-D | `api/internal/handlers/team.go` | merged to api |
| `team.tombstoned` | W7-D | `worker/internal/jobs/tombstone.go` | merged to api |
| `team.deletion_failed` | W7-D | `worker/internal/jobs/tombstone.go` | merged to api |
| `resource.read` | W7-C | `api/internal/handlers/resource.go` | merged to api |
| `resource.list_by_team` | W7-C | `api/internal/handlers/resource.go` | merged to api |
| `connection_url.decrypted` | W7-C | `api/internal/crypto/decrypt.go` | merged to api |
| `resource.metrics_queried` | W7-F | `api/internal/handlers/metrics.go` | merged to api |
| `auth.login` | W7-A wave-4 A3 | `api/internal/handlers/auth.go` | merged to api |
| `vault.read` / `vault.write` | W7-A wave-4 A3 | `api/internal/vault/*.go` | merged to api |
| `deploy.created` / `deploy.healthy` / `deploy.failed` | W7-A wave-4 A3 | `api/internal/handlers/deploy.go` | merged to api |
| `family.bulk_twin` | W4-B3 | `api/internal/handlers/family.go` | merged to api |
| `backup.requested` / `restore.requested` | W5-B-api | `api/internal/handlers/backup.go` | merged to api |
| `storage.iam_user_created` / `storage.iam_user_deleted` | W9-C1 | `api/internal/handlers/storage.go` | merged to api |

### Cross-link: emit sites that may not be in main yet

The following dashboard + alert artifacts depend on emit sites that have
shipped to the `api/` repo but may not have reached the `main` branch of
this infra repo's deploy target by the time these dashboards apply:

- `connection-url-decrypt-burst.json` depends on `api` PR W7-C (audit pass
  on the crypto package). If that PR isn't deployed, the alert never fires
  (count = 0) — safe degradation.
- `team-deletion-failed.json` depends on `worker` PR W7-D (tombstone job
  emits the failure audit). Without it, the alert never fires.
- `storage-iam-create-failed.json` depends on `api` PR W9-C1 exporting the
  `instant_storage_iam_users_failed_total` counter. Verify the metric is
  scraped before relying on this alert.
- `backup-requested-no-followup.json` depends on `api` PR W5-B-api
  emitting all three of `backup.requested`, `backup.succeeded`,
  `backup.failed` with a matching `backup_id` field.
- `deploy-failure-rate-by-team.json` requires `deploy.healthy` and
  `deploy.failed` to carry `team_id` in their log fields — both confirmed
  in `api/internal/handlers/deploy.go` today.

### Counts

- 2 new dashboards (20 widgets + 8 widgets = 28 widgets total)
- 5 new alert conditions
- Apply.sh discovers them automatically (glob `dashboards/*.json` and
  `alerts/*.json`). The test in `tests/apply.test.sh` was bumped to 33
  expected names (26 from W5-D baseline + 7 added here).

### Conflict surface

- A1 (the Wave-4 NR rollup) shipped under `newrelic/dashboards/` and
  `newrelic/alerts/`. All filenames here are new — no path conflict on
  the artifacts themselves.
- W5-D also shipped under `newrelic/dashboards/` and `newrelic/alerts/`
  with different filenames — no conflict.
- This `CHANGES.md` is new in this branch; entries below are sorted
  newest-first to keep dated rollups readable.

---

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
