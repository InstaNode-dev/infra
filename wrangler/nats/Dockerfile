# nats image for staging CF Container.
#
# Base: nats:2-alpine. JetStream needs durable disk — NOT viable on
# CF Containers' ephemeral storage — so this image runs CORE NATS ONLY
# (no -js flag). Customer-facing /queue/new in staging returns a
# legacy_open connection string and tests that exercise JetStream
# features are skipped (see test guard in api/internal/handlers/queue.go).
#
# Auth mode: legacy_open. Per CLAUDE.md "Known Design Gaps", prod
# serves legacy_open until the operator runs `nsc generate` for
# operator/sys NKeys (NATS-AUTH-RUNBOOK.md). Staging matches prod's
# current auth posture.

FROM nats:2-alpine

COPY infra/wrangler/nats/nats-server.conf /etc/nats/nats-server.conf

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8222/healthz | grep -q '"status":"ok"' || exit 1

EXPOSE 4222 8222

CMD ["-c", "/etc/nats/nats-server.conf"]
