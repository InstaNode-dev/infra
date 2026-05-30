# Cloudflare resources — Terraform

Source of truth for everything we declare in Cloudflare for the InstaNode
migration: API tokens (deploy + admin/tunnel), DNS records, R2 buckets,
Pages projects, and (later) Workers + Load Balancers + Page Rules.

> **k8s is NOT in scope here.** k8s manifests stay under `../../k8s/`,
> managed by `kubectl set image` + the existing per-service auto-deploy
> per CLAUDE.md rule 15. This dir is for Cloudflare-managed resources only.

## Decision references

This module implements:
- **D-1** (scope — R2, Pages, CF proxy on api, staging-only Tunnel)
- **D-2** (staging on full CF stack)
- **D-3** (per-service DNS-weighted cutover; TTL 60s ≥48h)
- **D-4** (separate `instant-staging-data` ns — k8s-side, not here, but the staging Pages project + R2 bucket parallel it)
- **D-7** (NS delegation is CF; already verified)
- **D-8** (R2 env-var canonical names: `R2_HMAC_KEY_ID` / `R2_HMAC_SECRET`)
- **D-14** (operator credentials — outputs from `tokens.tf` install via `make install-secrets`)

Source: `/tmp/cf-migration/shared/DECISIONS.md`.

## Bootstrap (one-time)

The TF state lives in R2, which means the R2 bucket for state and the
HMAC creds to write to it must exist BEFORE `terraform init`. Manual
chicken-and-egg step:

```bash
# 1. Create the state bucket via wrangler (operator-side, one time).
wrangler r2 bucket create instanode-tf-state --location wnam

# 2. Create R2 HMAC for state access only (scope: instanode-tf-state).
#    Dashboard → R2 → Manage R2 API Tokens → Create:
#      - Name: "tf-state-rw"
#      - Permission: Object Read & Write
#      - Specify buckets: instanode-tf-state
#    Save the Access Key ID + Secret + Endpoint.

# 3. Export the state-backend creds + CF auth token for terraform.
export AWS_ACCESS_KEY_ID="<tf-state-rw access key id>"
export AWS_SECRET_ACCESS_KEY="<tf-state-rw secret>"
export CLOUDFLARE_API_TOKEN="<Token A — instanode-migration-deploy>"

# 4. Init the backend with the env-specific account endpoint.
terraform init \
  -backend-config="endpoints={s3=\"https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com\"}"

# 5. Pick a workspace (staging first).
terraform workspace new staging
terraform workspace select staging

# 6. Plan + apply.
terraform plan -out=staging.tfplan
terraform apply staging.tfplan
```

After `apply` succeeds you have:
- Two CF API tokens in TF state (deploy + admin_tunnel).
- The staging Pages project + R2 bucket + DNS records.
- Output values for token secrets (sensitive — see next section).

## Installing token secrets into k8s + GH

Tokens are SENSITIVE outputs — they appear once in TF state and once
when `terraform output -raw <name>` is run. To install:

```bash
# Read the tokens (do NOT redirect to a file you'll commit).
DEPLOY_TOKEN="$(terraform output -raw deploy_token)"
ADMIN_TUNNEL_TOKEN="$(terraform output -raw admin_tunnel_token)"

# k8s — staging namespace.
kubectl create secret generic instant-secrets-cf \
  -n instant-staging \
  --from-literal=CLOUDFLARE_API_TOKEN="$DEPLOY_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# GH org / repo secrets — for CI auto-deploys.
for repo in instanodedev/api instanodedev/worker instanodedev/provisioner \
            instanodedev/instanode-web instanodedev/dashboard \
            instanodedev/infra; do
  gh secret set CLOUDFLARE_API_TOKEN -b"$DEPLOY_TOKEN" -R "$repo"
done

# Admin/tunnel token: ONLY into a separate operator-local Vault, never
# into CI. Used break-glass for Tunnel/Access changes.
op item create --category=ApiCredential --title="cf-admin-tunnel-staging" \
  --vault="instanode-prod" credential="$ADMIN_TUNNEL_TOKEN"

unset DEPLOY_TOKEN ADMIN_TUNNEL_TOKEN
```

## Workflow during the migration

1. **Plan-on-PR.** Every PR that changes a `.tf` file under this dir
   triggers `terraform plan` in CI; diff posted as PR comment.
2. **Apply-on-merge.** Merge to `main` triggers `terraform apply` via
   the workflow (gated on approval — `instanodedev/infra` already has
   manual-apply discipline; rule 15 doesn't auto-deploy `infra`).
3. **Per-PR contract checklist (rule 22)** still applies. A TF PR that
   adds a new host or changes the API base URL ALSO needs the
   synchronized code edits in `api/internal/handlers/openapi.go` +
   `content/llms.txt` + the dashboard/cli/mcp/sdk-go base-URL constants.
4. **Per-PR observability checklist (rule 25)** still applies. New
   resources that emit metrics need an `instant_*` Prom rule + NR alert
   JSON + dashboard tile + METRICS-CATALOG row in the same PR.

## Workspace conventions

- `terraform workspace new staging` / `terraform workspace new production`
- `terraform workspace select <env>` before any plan/apply
- `var.environment` is set automatically via `*.auto.tfvars` files
  selected by workspace (TF auto-loads `staging.auto.tfvars` when the
  workspace is `staging` if your CI passes `-var-file` accordingly;
  during interactive use, pass `-var-file=staging.auto.tfvars` explicit-
  ly to avoid surprises).

## File layout

| File | Purpose |
|---|---|
| `versions.tf` | TF + provider pinning, R2 backend config |
| `providers.tf` | CF provider (reads `CLOUDFLARE_API_TOKEN` env) |
| `variables.tf` | account_id, zone_id, environment, token expiries |
| `tokens.tf` | `cloudflare_account_token.deploy` + `.admin_tunnel` |
| `r2.tf` | R2 bucket + 24h-TTL lifecycle rule on `anon/` prefix |
| `dns.tf` | DNS records (apex / www / api / staging) with TTL 60s |
| `pages.tf` | Pages project for `instanode-web` (Phase 2) |
| `outputs.tf` | Sensitive token outputs (consumed by `make install-secrets`) |
| `staging.auto.tfvars` | Workspace-scoped vars for staging |
| `production.auto.tfvars` | Workspace-scoped vars for production |

## What's NOT here (yet)

- **Workers** — CEO D-1 deferred until measured TTFB benefit shows up.
- **Hyperdrive** — same; api and DO Managed PG are same-region, no win today.
- **D1** — KILLED per D-1.
- **CF Email Routing** — DEFERRED; outbound stays on Brevo.
- **Tunnels** — Phase 5 staging-only; add `tunnels.tf` when that PR ships, scoped to admin_tunnel token.
- **Load Balancers** — pending the CF Startups operator ticket (D-6, 5–10 day lead). Once enabled, add `lb.tf`.
- **Page Rules / Cache Rules** — Phase 4 only (api orange-cloud cut). Per D-12, the rule is an explicit path-allowlist for `/healthz`, `/openapi.json`, `/llms.txt`; NEVER Authorization-header-based.

## R2 HMAC keys (NOT here)

The R2 HMAC Access Key ID / Secret used by `common/storageprovider/r2/`
are SEPARATE from the CF API token and are generated via the R2 dashboard
"Manage R2 API Tokens" UI (NOT this Terraform). Reason: the
`cloudflare_r2_bucket` resource doesn't issue per-bucket HMAC pairs;
that's a one-off operator action, scoped to the specific bucket.

After Phase 0 creates the staging bucket, the operator runs:
1. Dashboard → R2 → Manage R2 API Tokens → Create
2. Permissions: Object Read & Write
3. Specify buckets: `instant-shared-staging` (NOT *Apply to all buckets*)
4. TTL: 180 days
5. Save the resulting `Access Key ID` + `Secret Access Key` into
   `instant-secrets` as `R2_HMAC_KEY_ID` + `R2_HMAC_SECRET` (D-8 names).

Repeat for `instant-shared` (prod) after staging passes 48h green (D-9).
