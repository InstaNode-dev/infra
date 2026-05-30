# pg-platform image for staging CF Container.
#
# Base: pgvector/pgvector:pg16 — Postgres 16 + the pgvector extension
# that platform_db's resource embeddings table requires (extension CREATE
# in mig 040+; without pgvector the image init fails on the first
# `CREATE EXTENSION vector` statement).
#
# Migrations: the 63 *.sql files from api/internal/db/migrations/ are
# copied into /docker-entrypoint-initdb.d/. Postgres's official
# entrypoint runs every *.sql alphabetically on first cluster init —
# and CF Containers' ephemeral disk means EVERY cold start IS a first
# cluster init, so the migrations re-apply on every wake-from-sleep.
#
# This is the explicit, user-blessed ephemeral-state tradeoff for the
# CF-only staging design. See ../README.md acceptance criterion.
#
# Build context: workspace root (../../).
# Build command (CI runs this; not for ad-hoc local use):
#   docker buildx build \
#     -f infra/wrangler/pg-platform/Dockerfile \
#     -t ghcr.io/instanode-dev/instant-pg-platform:staging \
#     --push \
#     .

FROM pgvector/pgvector:pg16

# Copy every migration file in numeric (=alphabetical) order. The
# leading 0NN_*.sql naming guarantees the entrypoint applies them in
# the same order as `make test-db-up` does locally.
COPY api/internal/db/migrations/*.sql /docker-entrypoint-initdb.d/

# A pre-script that runs before any migration. Names start with "00_"
# so it sorts ahead of "001_initial.sql".
#
# We use it to:
#   1. CREATE EXTENSION pgvector (idempotent — base image has the
#      shared lib; this enables it in the freshly-init'd database).
#   2. Set timezone to UTC to match production.
#   3. Print a one-line marker so the CF Container's logs make clear
#      this is a fresh init (operator confidence on cold start).
COPY infra/wrangler/pg-platform/00_pre.sql /docker-entrypoint-initdb.d/00_pre.sql

# postgres image expects POSTGRES_PASSWORD set; staging wrangler.toml
# wires that through `wrangler secret put POSTGRES_PASSWORD`. The
# image also reads POSTGRES_DB / POSTGRES_USER if provided (wrangler
# env block sets POSTGRES_DB=instant_platform).

# Healthcheck — pg_isready against the local socket. Used by the
# Worker shell's container.fetch wait-loop.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-instant_platform}" || exit 1

EXPOSE 5432
