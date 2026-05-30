# api — CF Containers staging deploy

Wraps the Go api binary (port 8080) in a CF Container. Image pulled from
`ghcr.io/instanodedev/api:staging` — built by the api repo's CI on every
push to master, tagged with `:staging` for staging deploys.

## Env vars and secrets

Config (committed):
- `ENVIRONMENT=staging`
- `OBJECT_STORE_BACKEND=r2`
- `R2_BUCKET_NAME=instant-shared-staging`

Secrets (via `wrangler secret put`):
- `DATABASE_URL` — points at `pg-platform` Container DO via service binding
- `CUSTOMER_DATABASE_URL` — points at `pg-customers` Container DO
- `REDIS_URL` — service binding to `redis-platform`
- `NATS_URL` — service binding to `nats`
- `AES_KEY`, `JWT_SECRET`, `RAZORPAY_WEBHOOK_SECRET`, `BREVO_API_KEY` — same names as k8s prod
- `R2_HMAC_KEY_ID`, `R2_HMAC_SECRET` — from R2 dashboard, scoped to `instant-shared-staging` bucket

## Deploy

```bash
cd infra/wrangler/api
wrangler containers deploy --env staging
```

CI auto-deploys on merge to master via the workflow in `infra/.github/workflows/`.

## Known constraints

- **Disk wipes on sleep** — api itself is stateless so this is fine; downstream PG/Mongo are NOT (see ../README.md acceptance criterion).
- **HTTP only** — gRPC api→provisioner is fine (CF Containers support HTTP/2).
- **No persistent customer port-forwards** — the dashboard's port-forward proxy is disabled on staging.
