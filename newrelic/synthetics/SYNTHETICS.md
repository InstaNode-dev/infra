# Synthetic monitoring + silent-failure alerting

This directory and the new `../alerts/*.json` conditions exist to catch the
class of **silent production failures** that this session surfaced — failures
where the system was broken for real customers and *nothing alerted*:

- The prod paid funnel was completely dead ("seller does not support recurring
  payments") — checkouts created, no charge webhook ever arrived.
- The Razorpay webhook `default:` case silently swallowed unhandled events.
- A customer could be charged and never upgraded, with nothing noticing.

Every monitor and alert below keys on a signal the application **already
emits** — no new app code is required. The billing-trust fixes deployed this
session emit the `billing.charge_undeliverable` audit kind, the
`billing.webhook.unhandled_event` WARN log, and the
`instant_billing_reconciler_orphan_corrected_total` /
`instant_entitlement_drift_corrected_total` metrics; the alerts simply observe
them.

---

## Synthetic monitors (`synthetics/*.json`)

NR Synthetics monitors. Each `.json` is a normalized definition;
`../synthetics-apply.sh` translates it to the right NerdGraph mutation
(`syntheticsCreate{Simple,SimpleBrowser,ScriptApi}Monitor`) and is idempotent
by monitor name.

| Monitor | Kind | Target | Period | Catches |
|---|---|---|---|---|
| `instant-api healthz ping` | SIMPLE | `https://api.instanode.dev/healthz` | 5 min | API down / unreachable / TLS broken — agents cannot provision. |
| `instanode marketing home ping` | SIMPLE | `https://instanode.dev/` | 5 min | Marketing surface down — top-of-funnel dead. |
| `instanode dashboard login page` | BROWSER | `https://instanode.dev/app` | 5 min | Dashboard SPA fails to mount (e.g. stale-deploy chunk 404) — customers cannot log in. BROWSER, not SIMPLE, so the empty `index.html` shell does not pass a broken bundle. |
| `instant-api openapi.json ping` | SIMPLE | `https://api.instanode.dev/openapi.json` | 15 min | API contract surface unreachable — agents/MCP lose their schema. |
| `instant-api healthz scripted (build-SHA freshness)` | SCRIPT_API | `/healthz` body assertions | 15 min | Asserts `ok=true`, `commit_id` is non-placeholder (not `dev`/`unknown`), `migration_status=ok`, and `build_time` ≤ 30 days old — catches stale-image deploys, un-instrumented builds, and schema drift a status-code ping misses. Script: `scripts/api-healthz-scripted.js`. |

A failed check surfaces as a `SyntheticCheck` event with `result = 'FAILED'`,
which the `api-healthz-down` alert keys on.

---

## Alert conditions (`../alerts/*.json`)

Applied by `../apply.sh` onto the umbrella policy `instant-api alerts`.
Eight new conditions were added for this work:

| Alert file | Severity | Signal | Threshold | Catches |
|---|---|---|---|---|
| `billing-charge-undeliverable.json` | **CRITICAL** | `Log` `audit_kind = 'billing.charge_undeliverable'` | ABOVE 0 (any single occurrence, 5m) | A customer was charged but the upgrade could not be delivered. Highest severity — operator must reconcile/refund. |
| `billing-webhook-unhandled-event.json` | WARNING | `Log` `message = 'billing.webhook.unhandled_event'` | ABOVE 0 (any single occurrence, 5m) | The Razorpay webhook `default:` case hit an event type the handler does not recognise — a coverage gap. |
| `billing-reconciler-orphan-corrected.json` | WARNING | `Metric` `instant_billing_reconciler_orphan_corrected_total` | ABOVE 0 (15m) | Paid customers are slipping past the primary webhook path and only the reconciler safety net caught them. |
| `entitlement-drift-corrected.json` | WARNING / CRITICAL | `Metric` `instant_entitlement_drift_corrected_total` | WARN ABOVE 3 / CRIT ABOVE 20 (rolling 1h) | Tier upgrades/downgrades are not propagating entitlement changes — resources on wrong limits. |
| `zero-upgrades-7d.json` | **CRITICAL** | `Log` `audit_kind = 'subscription.upgraded'` | BELOW_OR_EQUALS 0 sustained 7 days | Dead paid funnel — would have fired the day the "seller does not support recurring payments" outage began. |
| `checkout-failure-spike.json` | WARNING / CRITICAL | `Log` ERROR + `message LIKE '%checkout%'` | WARN ABOVE 3 / CRIT ABOVE 15 per hour | `POST /billing/checkout` is failing before any charge — the buy button is broken. |
| `api-healthz-down.json` | WARNING / CRITICAL | `SyntheticCheck` `result = 'FAILED'` on the healthz monitors | WARN 1 / CRIT 2 consecutive failed checks | api pod down / unreachable / `/healthz` failing. |
| `backend-service-no-logs.json` | **CRITICAL** | `Log` count FACET `service` | BELOW 1 for 10m | Any of api / worker / provisioner emitted zero logs for 10m — a crashed/evicted/deadlocked pod, faceted so the violation names the dead service. Covers worker + provisioner, which have no public HTTP surface to ping. |

Elevated api 5xx rate is already covered by the pre-existing
`../alerts/api-5xx-rate-high.json` (`instant-api — 5xx rate > 1% (5m)`) — no
duplicate added.

### Threshold rationale

- **`ABOVE 0` (single occurrence)** on `billing-charge-undeliverable` and
  `billing-webhook-unhandled-event`: these events are rare and each one is a
  real, individually actionable problem. No "rate" makes sense — one is too
  many.
- **`zero-upgrades-7d`** uses a 7-day (`604800s`) static low-baseline window
  rather than a NR Baseline condition: early-stage upgrade volume is too sparse
  for anomaly math, so *any* 7-day stretch with zero upgrades is itself the
  anomaly. RE-TUNE to a Baseline condition once steady upgrade volume exists.
- **`entitlement-drift-corrected`** WARN at `>3/h`: one stray drift correction
  is steady-state noise; a sustained rate is a broken propagation path.
- **`checkout-failure-spike`** low absolute thresholds (`>3/h` WARN): at current
  funnel volume even a handful of failed checkouts is most of the funnel.
- **`api-healthz-down`** requires 2 consecutive failed checks for CRITICAL
  (~10m at the 5-min monitor period) to ride out a single transient blip.

---

## Apply

The `infra` repo has **no auto-apply** — definitions are committed here and
applied manually (or by the operator) via the NR API.

```bash
export NEW_RELIC_API_KEY=NRAK-...        # User key with Synthetics + Alerts admin scope
export NEW_RELIC_ACCOUNT_ID=7958263      # instanode.dev prod account

# Validate everything + preview, no API calls:
./apply.sh --dry-run                     # dashboards + alerts
./synthetics/../synthetics-apply.sh --dry-run   # synthetic monitors

# Apply for real:
./apply.sh                               # creates/updates dashboards + the 8 new alert conditions
./synthetics-apply.sh                    # creates/updates the 5 synthetic monitors
```

Both scripts are idempotent — re-run any time; they look resources up by name
and create-or-update. `synthetics-apply.sh` lives next to `apply.sh` in
`newrelic/`.
