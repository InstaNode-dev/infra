# pg-platform — staging CF Container

Postgres 16 + pgvector. Image baked with all 63 platform migrations in
`/docker-entrypoint-initdb.d/` so cold starts come up with a fully
migrated schema.

## Ephemeral acceptance

Per the CF-only staging decision (2026-05-30): disk wipes every time the
Container sleeps (which fires on traffic-quiet, not just intentional
restart). Each cold start:

1. CF Containers wakes the Container with a fresh disk.
2. Postgres entrypoint sees PGDATA empty → runs `initdb`.
3. `00_pre.sql` runs first — pgvector + uuid-ossp + pgcrypto extensions, UTC tz.
4. The 63 migration files run in numeric order (001 → 063).
5. Container reports healthy via `pg_isready`.
6. api / worker / provisioner Containers can now connect via service binding.

Total cold-start time: estimated 15–45s depending on Container class +
migration count. Anything that talks to pg-platform must tolerate this
warmup (Worker shell's `container.fetch` blocks until healthy).

## Image build

The image is built by `infra/.github/workflows/wrangler-build-staging-images.yml`
on push to master that changes any of:
- `api/internal/db/migrations/**` (cross-repo trigger via repository_dispatch — see below)
- `infra/wrangler/pg-platform/**`

Plus daily at 09:00 UTC to keep up with migrations merged in api repo without
explicit infra commits.

Manual rebuild:
```bash
gh workflow run wrangler-build-staging-images.yml \
  -R instanode-dev/infra \
  -f service=pg-platform
```

## Cross-repo migration sync

Migrations live in the `api` repo, not infra. Two patterns to keep the
image current:

1. **Daily cron rebuild** — the build workflow runs nightly with a fresh
   checkout of both repos; any new `.sql` file lands within 24h.
2. **`api` repo notifies on migration change** — `api/.github/workflows/notify-infra-on-migration.yml`
   sends a `repository_dispatch` event to infra when `api/internal/db/migrations/**`
   changes, triggering an immediate build.

If neither runs, staging pg-platform will be behind on migrations and
api startup will fail with "migration not applied" — operator-visible
via `wrangler tail instanode-pg-platform-staging`.

## Secrets

Set via `wrangler secret put`, scoped to `--env staging`:

| Secret | Source | Purpose |
|---|---|---|
| `POSTGRES_USER` | operator-defined (e.g. `instanode_admin`) | role for connection |
| `POSTGRES_PASSWORD` | random, ≥32 chars | passed to connection_url |
| `POSTGRES_DB` | `instant_platform` | initial DB created at first start |

The actual connection string handed to api/worker/provisioner is built
via service binding — they see `PG_PLATFORM` env binding, not a raw
URL with the password.

## Verifying

```bash
wrangler tail instanode-pg-platform-staging --format pretty
# wait for: "pg-platform staging cold start — re-applying 63 migrations against fresh PGDATA"
# then:    "database system is ready to accept connections"

# from a debug Worker shell:
wrangler dev --env staging
# Then inside the Worker: env.PG_PLATFORM.fetch("http://internal/healthz")
```

## Known limitations

- **Cold-start cost is ~15-45s.** Synthetic warmer can keep it hot; without one, every traffic gap > sleepAfter (currently 30m) pays the full re-migration cost.
- **No replication.** max_instances=1; HA is meaningless when disk is ephemeral. Production gets a different model entirely.
- **No `pg_dump` artifacts persist.** If you need a snapshot for debugging, dump and immediately stream to R2 via the customer-backup pipeline; the local file dies on next sleep.
- **63 migrations is the live count as of 2026-05-30.** When api repo adds mig 064+, the daily cron rebuild picks them up.
