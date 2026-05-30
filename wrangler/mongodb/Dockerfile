# mongodb image for staging CF Container.
#
# Base: mongo:7. CF Containers' ephemeral disk means EVERY cold start
# is a fresh init — there is no "first init vs subsequent restart"
# distinction. The mongo image's docker-entrypoint runs initdb scripts
# on every fresh /data/db, so the staging-bootstrap script below runs
# every cold start.
#
# Why custom (vs pristine mongo:7):
#   - Bake the staging-bootstrap that creates the admin user + sets
#     the wire compression default so api can connect without
#     post-deploy operator action.
#   - Healthcheck via `mongosh ping` for the Worker shell's wait loop.
#   - Per-tenant database names are CREATED on demand by provisioner;
#     no per-tenant schema baked in here.

FROM mongo:7

# Staging-bootstrap: idempotent admin user. Mongo entrypoint reads
# MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD from env on
# first init; this script is a defence-in-depth ensure path used by
# the api's connection-test against `db.adminCommand({ ping: 1 })`.
COPY infra/wrangler/mongodb/docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

# `mongosh` is in the base image; the healthcheck just exercises a
# round-trip via the admin DB to confirm the daemon is up + responsive.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD mongosh --quiet --eval "db.adminCommand({ping:1}).ok" --host=localhost | grep -q '^1$' || exit 1

EXPOSE 27017
