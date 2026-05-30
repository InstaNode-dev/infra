# redis-provision image for staging CF Container.
#
# Base: redis:7-alpine. CF Containers' ephemeral disk means RDB
# persistence is pointless — every sleep wipes /data. We disable
# RDB + AOF entirely and run in-memory-only with `allkeys-lru`
# eviction so the Container can't OOM under sustained writes.
#
# Why custom (vs pristine redis:7-alpine):
#   - Bake redis.conf with auth + memory + eviction policy so the
#     Worker shell doesn't have to pass them via wrangler.toml CMD.
#   - Healthcheck via `redis-cli -a $REDIS_PASSWORD ping`.
#   - Auth is via `requirepass` from REDIS_PASSWORD env (wrangler
#     secret).

FROM redis:7-alpine

COPY infra/wrangler/redis-provision/redis.conf /etc/redis/redis.conf

# Entrypoint that templates REDIS_PASSWORD env into the conf at boot.
# Without this, the conf can't contain the secret at build time.
COPY infra/wrangler/redis-provision/entrypoint.sh /usr/local/bin/staging-entrypoint.sh
RUN chmod +x /usr/local/bin/staging-entrypoint.sh

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping | grep -q '^PONG$' || exit 1

EXPOSE 6379

ENTRYPOINT ["/usr/local/bin/staging-entrypoint.sh"]
CMD ["redis-server", "/etc/redis/redis.conf"]
