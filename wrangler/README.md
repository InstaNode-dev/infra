# Wrangler — CF Containers for staging

This directory deploys instanode.dev services as **Cloudflare Containers**
to the **staging** environment. Each service has its own subdir with a
`wrangler.toml` + a tiny Worker shell (`src/worker.ts`) that exposes the
Container via a Durable Object binding.

Production does NOT use this — see the `production-` workflow when written.
Per user direction 2026-05-30: staging is CF-only, ephemeral state acceptable.

## Why wrangler, not Terraform

The `cloudflare/cloudflare` Terraform provider (v5.19.1 as of bootstrap) does
NOT yet expose a `cloudflare_container` resource. Verified by `terraform
providers schema -json | jq '.. | keys?' | grep container` → empty.

Until the provider catches up, we manage Containers via `wrangler` and
**Terraform manages everything else**: DNS, R2, Pages, Hyperdrive, KV,
Queues, secrets — see `../terraform/cloudflare/`.

When `cloudflare_container` ships, we'll swap in. Until then, the
boundary is clean:

| Surface | Tool |
|---|---|
| DNS records, R2 buckets, Pages projects, Hyperdrive config, API tokens | **Terraform** (`../terraform/cloudflare/`) |
| CF Containers (api/worker/provisioner + stateful staging services) | **Wrangler** (this dir) |
| k8s manifests (production data plane until that migrates) | **kubectl** (`../k8s/`) |

## Ephemeral-state acceptance criterion

CF Containers wipe disk every time an instance goes to sleep (which fires
on traffic-quiet, not just intentional restart). Source:
https://developers.cloudflare.com/containers/platform-details/

This means our staging Postgres / Mongo / Redis / NATS containers WILL
lose their data, mid-test sometimes. E2E test design MUST tolerate this:

1. **Every test seeds its own fixtures** at start; no test assumes state
   from a prior test.
2. **No "deploy now, verify in 2h" tests** — the container may have
   slept and lost its state in between.
3. **Tests that span multiple HTTP calls** must complete within one
   container-active window (typically minutes).
4. **`/db/new` in staging** returns a connection string that may stop
   working when the backing Container sleeps. Documented in the staging
   API responses.
5. **Synthetic monitors** keep the high-traffic Containers warm; cold
   ones are accepted as ephemeral.

These tradeoffs are explicit and user-blessed per the CF-only staging
decision. Production has a different host (TBD — not in this dir).

## Per-service layout

Each subdir contains:

```
infra/wrangler/<service>/
├── wrangler.toml          # CF Container + Worker config
├── src/
│   └── worker.ts          # Tiny Worker shell that wraps the Container DO
├── Dockerfile             # Optional override; defaults to ../../<repo>/Dockerfile
└── README.md              # Service-specific notes (image source, env vars, ports)
```

The actual service code (api, worker, provisioner) lives in its own repo
under `instanodedev/` and produces a Docker image that wrangler ships.
For services without a separate repo (pg-platform, pg-customers, mongodb,
redis-provision, nats), we use upstream public images (`postgres:16`,
`mongo:7`, `redis:7`, `nats:2`) and a small staging-only init script.

## Deploy

CI auto-deploys on merge to `master` via `../.github/workflows/wrangler-deploy-staging.yml`.
Manual deploy from an operator workstation:

```bash
cd infra/wrangler/<service>
wrangler login                           # one-time
wrangler containers deploy --env staging
```

Requires `CLOUDFLARE_API_TOKEN` env (Token A from the TF outputs).

## Service inventory

| Subdir | What runs | Stateful? | Public hostname (staging) | Notes |
|---|---|---|---|---|
| `api/` | instanode.dev api binary | no | `api.staging.instanode.dev` | HTTP only |
| `worker/` | River job worker | no | none (cron) | Triggered by CF Cron |
| `provisioner/` | gRPC :50051 service | no | private (Container→Container only) | api calls it |
| `pg-platform/` | postgres:16 | **yes, ephemeral** | private | `instance_type=standard`; data wiped on sleep |
| `pg-customers/` | postgres:16 | **yes, ephemeral** | `pg-customer-<tenant>.staging.instanode.dev` (one per tenant) | Customer-facing in staging only |
| `mongodb/` | mongo:7 | **yes, ephemeral** | private | accessed by /nosql/new staging |
| `redis-provision/` | redis:7 | **yes, ephemeral** | `redis-<tenant>.staging.instanode.dev` | Customer-facing |
| `nats/` | nats:2 (no JetStream — JS needs durable disk) | **yes, ephemeral** | `nats-<tenant>.staging.instanode.dev` | Core NATS only in staging |
