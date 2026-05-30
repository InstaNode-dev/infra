#!/bin/sh
# Templating entrypoint for staging redis. Inlines REDIS_PASSWORD into
# /etc/redis/redis.conf at boot (the file ships with __REDIS_PASSWORD__
# as a literal marker; we never bake a real secret into the image).

set -eu

if [ -z "${REDIS_PASSWORD:-}" ]; then
  echo "redis-provision: REDIS_PASSWORD env var is required" >&2
  exit 1
fi

# In-place substitute. Using a temp file because sed -i on alpine
# behaves differently than GNU sed; this is portable.
TMP="$(mktemp)"
sed "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|" /etc/redis/redis.conf > "$TMP"
mv "$TMP" /etc/redis/redis.conf
chmod 600 /etc/redis/redis.conf  # only root reads — defense in depth

# Hand off to the configured CMD (`redis-server /etc/redis/redis.conf`).
exec "$@"
