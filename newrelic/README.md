# New Relic dashboards + alerts

This directory holds the JSON definitions for the instant-api dashboards
and alert conditions, plus tooling to apply them to a New Relic account.

The JSON files in `dashboards/` and `alerts/` are the source of truth —
copied here from api PR #34, which committed them but never applied them
to the live account.

## Layout

```
newrelic/
├── apply.sh                 ← bash script (primary path)
├── dashboards/              ← NerdGraph DashboardInput JSON
│   ├── api-overview.json
│   ├── deploy.json
│   ├── provisioning.json
│   └── worker.json
├── alerts/                  ← NerdGraph NrqlConditionStaticInput JSON
│   ├── error-rate-high.json
│   ├── nats-down.json
│   ├── p95-latency-high.json
│   └── worker-stalled.json
├── terraform/               ← Terraform alternative (same JSON, different runtime)
│   └── main.tf
└── tests/
    └── apply.test.sh
```

## Path A — `apply.sh` (recommended for first-time setup)

One-shot bash script. POSTs each JSON file to NerdGraph via `curl + jq`.
Idempotent: looks resources up by name and creates or updates as needed.

### Prerequisites

- `curl` and `jq` on PATH.
- A New Relic **User Key** (`NRAK-...`) with admin permissions to manage
  dashboards and alerts. **Not** the license key (`NRAL-...`) — that one
  is ingest-only.
- The numeric account ID.

### Run

```bash
export NEW_RELIC_API_KEY=NRAK-...
export NEW_RELIC_ACCOUNT_ID=1234567

# Optional:
# export NEW_RELIC_REGION=US        # or EU
# export NEW_RELIC_POLICY_NAME='instant-api alerts'

./apply.sh --dry-run   # print what would happen, no API calls
./apply.sh             # apply for real
```

Re-run as often as you like. The script:

1. Validates every JSON file parses before any API call.
2. For each dashboard: searches by name in the account; updates if found,
   else creates. Substitutes `accountIds: [0]` placeholders with
   `$NEW_RELIC_ACCOUNT_ID` at apply time.
3. Finds (or creates) the umbrella alert policy
   (default name: `instant-api alerts`).
4. For each NRQL condition: searches by name within the policy; updates
   if found, else creates.
5. Prints each name + the resulting URL.

### Test it

```bash
bash tests/apply.test.sh
```

Covers env-var guards, JSON validation, `--dry-run` output, unknown-flag
handling, and corrupted-JSON behaviour. No real API calls.

## Path B — Terraform (recommended for ongoing ops)

Terraform tracks state in `terraform.tfstate`, which avoids the name-based
lookups `apply.sh` does on every run. Use this if you already standardize
on Terraform for infra.

```bash
cd terraform
export NEW_RELIC_API_KEY=NRAK-...
export TF_VAR_newrelic_account_id=1234567

terraform init
terraform plan
terraform apply
```

The `main.tf` reads the same `dashboards/*.json` and `alerts/*.json`
files used by `apply.sh`, so the JSON stays a single source of truth.

## When to use which

| Concern                                     | apply.sh | Terraform |
|---------------------------------------------|----------|-----------|
| Zero state file to manage                   | yes      | no        |
| Survives "someone hand-edited in the UI"    | yes (re-converges by name) | no (drift) |
| Plan/apply diff before mutating             | partial (`--dry-run`) | yes (`terraform plan`) |
| Provider-version churn                      | low      | medium    |
| Easy CI integration                         | yes      | yes       |

For the immediate post-rotation step in the task that produced this dir,
`apply.sh` is the right path. Adopt Terraform when the platform team
standardizes on it.

## Schema notes / gaps from api PR #34

The JSON files committed in api PR #34 are mostly NerdGraph-shaped, with
two adjustments handled at apply time rather than by editing the JSON:

1. **Dashboard `accountIds: [0]`.** Every dashboard widget has
   `accountIds: [0]` as a placeholder. `apply.sh` rewrites this to the
   real `$NEW_RELIC_ACCOUNT_ID` via `jq walk(...)` before POSTing.

2. **Alert `type: "NRQL"` field.** NerdGraph's `NrqlConditionStaticInput`
   doesn't accept a `type` discriminator (the mutation name encodes that),
   so `apply.sh` strips it via `jq 'del(.type)'`.

3. **Alert policy.** Conditions live under an `alertsPolicy`. PR #34 didn't
   commit a policy definition, so `apply.sh` find-or-creates a single
   umbrella policy named `instant-api alerts` and attaches all four
   conditions to it. Override via `NEW_RELIC_POLICY_NAME`.

If the JSON ever drifts from NerdGraph's schema in a way the adapter
above can't paper over, `apply.sh` will fail loud (NerdGraph returns
descriptive errors in the `errors[]` field).

## Resources applied

Dashboards (4):
- `instant-api — overview`
- `instant-api — deploy`
- `instant-api — provisioning`
- `instant-worker — River jobs`

Alert conditions (4):
- `instant-api — error rate > 1% (5m)`
- `instant-api — p95 latency > 500ms (5m)`
- `instant-api — NATS connection failures`
- `instant-worker — no jobs processed in 10m`
