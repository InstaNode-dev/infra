# Documentation — instanode.dev

> Everything you need to provision, deploy, and claim. Every curl below works against `https://api.instanode.dev` as-is.

## idempotency.md

# Idempotency

Every `POST` endpoint that creates a resource on `https://api.instanode.dev` is idempotent. Two layered guards cover the full retry matrix so an accidental double-create never costs you a duplicate database, a duplicate Razorpay subscription, or a duplicate team-invite email.

## Two layers, one contract

### 1. Explicit `Idempotency-Key` header (Stripe-shape, 24h TTL)

The standard mechanism. Generate a UUID per *logical* attempt and pass it on every retry:

```bash
KEY=$(uuidgen)
curl -X POST https://api.instanode.dev/db/new \
  -H "Idempotency-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-database"}'
```

- The first response is cached for **24 hours** in the per-tenant key space (`team_id` when authenticated, network fingerprint when anonymous).
- Every subsequent call carrying the same key replays the cached response verbatim with `X-Idempotent-Replay: true`.
- Reusing the same key with a *different* request body returns `409 idempotency_key_conflict` — that's almost always a client bug (the key should change when the work changes).
- Replays still consume rate-limit budget (anti-abuse) but do **not** consume quota budget (the original call already did).

Use the explicit header when you need exactly-once across a long window — e.g. a deploy job that may not retry for several minutes, a billing checkout the user might re-click after lunch.

### 2. Body-fingerprint fallback (120s TTL)

When the caller omits `Idempotency-Key`, the server still protects against double-creates by synthesising a fallback key from `sha256(scope, route, canonical-body)`:

- Scope = `team_id` when authenticated, network fingerprint (`/24` subnet + ASN) when anonymous.
- Route = the registered route pattern (e.g. `/db/new`), not the full URL.
- Canonical body = JSON keys sorted recursively for `application/json`; SHA-256 of the file content + sorted form fields for `multipart/form-data` (used by `/deploy/new`).

Two POSTs from the same caller, to the same route, with the same body, within 120 seconds → the second replays the first. Mobile double-taps, browser back-button resubmits, agent retries on transient 5xx, and reverse-proxy network-blip retries are all absorbed.

The 120s window is deliberately short. If you need true exactly-once across a longer window, pass an explicit `Idempotency-Key` (which gets the full 24h cache).

### Worked example: a double-click produces one resource

The simplest demonstration is two back-to-back `/db/new` calls from the same caller with the same body. Without `Idempotency-Key`, the fingerprint fallback collapses them:

```bash
# Two POSTs ~50ms apart — same caller, same body, no Idempotency-Key.
curl -sS -D /tmp/h1 -X POST https://api.instanode.dev/db/new \
  -H 'Content-Type: application/json' -d '{"name":"my-db"}' > /tmp/r1.json &
curl -sS -D /tmp/h2 -X POST https://api.instanode.dev/db/new \
  -H 'Content-Type: application/json' -d '{"name":"my-db"}' > /tmp/r2.json &
wait

grep -i "X-Idempotency-Source\|X-Idempotent-Replay" /tmp/h1 /tmp/h2
#   /tmp/h1:X-Idempotency-Source: miss
#   /tmp/h2:X-Idempotency-Source: fingerprint
#   /tmp/h2:X-Idempotent-Replay: true

jq -r .token /tmp/r1.json /tmp/r2.json
#   tok_3jX...               (same token on both — one resource was created)
#   tok_3jX...
```

The second call replays the first response verbatim. Only one Postgres database was provisioned. The same shape holds for `/deploy/new` (multipart, canonicalised by hashing the tarball + sorted form fields) and for `/api/v1/billing/checkout` (where the dashboard's client-side debounce, this fingerprint fallback, and the per-team `checkout_in_flight` SETNX guard layer to make sure a double-click never charges twice).

## Response headers

Every response from a create endpoint carries:

| Header | Values | Meaning |
| --- | --- | --- |
| `X-Idempotency-Source` | `explicit` | Caller passed an `Idempotency-Key`; the explicit cache served or stored the response. |
| `X-Idempotency-Source` | `fingerprint` | The body-fingerprint cache served the response (it had been seen in the last 120s). |
| `X-Idempotency-Source` | `miss` | Handler ran fresh. The fingerprint cache will store the response for the next 120s. |
| `X-Idempotent-Replay` | `true` | The response body was served from the cache (either path). Absent on fresh handler runs. |

Agents can branch on `X-Idempotency-Source` to distinguish "I just created this" from "I created this earlier and the server replayed".

## Covered endpoints

Idempotency is automatic on every POST that creates a resource:

- Provisioning: `/db/new`, `/cache/new`, `/nosql/new`, `/queue/new`, `/storage/new`, `/webhook/new`, `/vector/new`.
- Compute: `/deploy/new`, `/stacks/new`, `/stacks/{slug}/redeploy`, `/api/v1/resources/{id}/backup`, `/api/v1/resources/{id}/restore`, `/api/v1/resources/{id}/provision-twin`, `/api/v1/families/bulk-twin`, `/api/v1/stacks/{slug}/promote`.
- Billing + team: `/api/v1/billing/checkout`, `/api/v1/team/members/invite`, `/api/v1/teams/{team_id}/invitations`, `/api/v1/auth/api-keys`.
- Vault: `/api/v1/vault/{env}/{key}/rotate`. Each call inserts a new versioned secret row; dedup prevents double-click duplicate versions. `PUT /api/v1/vault/{env}/{key}` is state-replacement by contract (caller supplies the value) and `DELETE` is idempotent by construction, so neither needs the middleware.

`DELETE`, `PATCH`, and read-only `GET` routes are not covered — they're either intrinsically idempotent (state-replacement) or token-bound single-use (e.g. `/claim`).

## Fail-open posture

If Redis (the cache backing the idempotency state) is unavailable, the middleware logs a warning and falls through to the handler. Idempotency degrades to "no dedup", never to "cannot create resource". Defense in depth — handler-level dedup mechanisms (per-fingerprint daily caps on provisioning, unique-index constraints on connections) still apply.

## Why this matters for AI agents

An autonomous agent that retries on transient 5xx without idempotency creates a duplicate resource every time the upstream wobbles. With the fingerprint fallback on by default, those retries are now safe even when the agent doesn't manage retry keys. With the explicit header, you get the same guarantee across arbitrarily long retry windows. Either way: one logical attempt produces exactly one resource.

## Quickstart

The whole platform fits in one curl. No signup, no API key, no Docker.

```
curl -X POST https://api.instanode.dev/db/new \
  -H "Content-Type: application/json" \
  -d '{"name":"prod-db"}'
```

Every provisioning endpoint **requires** a `name` — a human-readable label
1–64 characters long, matching `^[A-Za-z0-9][A-Za-z0-9 _-]*$` (start with a
letter or digit; letters, digits, spaces, underscores and hyphens after).
Omitting it returns `400 {"error":"name_required"}`; an invalid value
returns `400 {"error":"invalid_name"}`.

The response includes a `connection_url` you can paste into any Postgres
client. The database is real, dedicated, and yours for 24 hours.

When you're ready to keep it, see the **Claim flow** section below.

## The seven services

Every endpoint returns a `connection_url` (or `endpoint` / `receive_url` /
application URL) plus an `upgrade_jwt` you can hand to /claim.

- `POST /db/new` — Postgres (pgvector pre-installed)
- `POST /cache/new` — Redis (ACL'd, per-token key prefix)
- `POST /nosql/new` — MongoDB
- `POST /queue/new` — NATS JetStream
- `POST /storage/new` — S3-compatible (DigitalOcean Spaces, `nyc3`)
- `POST /webhook/new` — public URL that receives any HTTP method
- `POST /deploy/new` — container deploy (tarball in, HTTPS URL out)

## The required `name` field

Every provisioning endpoint above — plus `/stacks/new` —
**requires** a `name`. It is the human-readable label shown in the dashboard
and in `GET /api/v1/resources`.

- Send `name` as a JSON string field on `/db/new`, `/cache/new`, `/nosql/new`,
  `/queue/new`, `/storage/new`, `/webhook/new`, and `/stacks/new`.
- `/deploy/new` and `/stacks/new` are multipart — pass `name` as a form field.
- **Validation:** 1–64 characters, must match `^[A-Za-z0-9][A-Za-z0-9 _-]*$`
  (start alphanumeric; letters, digits, spaces, underscores, hyphens after).
- Omitting `name` → `400 {"error":"name_required"}`.
- An invalid value → `400 {"error":"invalid_name"}`.

```
curl -X POST https://api.instanode.dev/db/new \
  -H "Content-Type: application/json" \
  -d '{"name":"prod-db"}'

curl -X POST https://api.instanode.dev/cache/new \
  -H "Content-Type: application/json" \
  -d '{"name":"sessions-cache"}'

curl -X POST https://api.instanode.dev/nosql/new \
  -H "Content-Type: application/json" \
  -d '{"name":"events-store"}'

curl -X POST https://api.instanode.dev/queue/new \
  -H "Content-Type: application/json" \
  -d '{"name":"jobs-queue"}'

curl -X POST https://api.instanode.dev/storage/new \
  -H "Content-Type: application/json" \
  -d '{"name":"uploads-bucket"}'

curl -X POST https://api.instanode.dev/webhook/new \
  -H "Content-Type: application/json" \
  -d '{"name":"github-webhook"}'
```

Most responses share the shape `{ ok, token, connection_url, internal_url,
tier, limits, note, upgrade_jwt }`. `internal_url` is the address to use
when the caller itself runs inside our cluster (i.e. via /deploy/new) —
public hostnames don't hairpin reliably from inside. Two endpoints differ:
`/webhook/new` returns `receive_url` (no `connection_url`/`internal_url`), and
`/storage/new` returns `endpoint`/`prefix`/`mode` (and, in `broker` mode, a
`presign_url` instead of S3 keys — see Storage isolation below).

### NATS queue credentials (2026-05-20+)

The `/queue/new` response also includes a `credentials` object with per-tenant
NATS account credentials (MR-P0-5):

```json
{
  "ok": true,
  "connection_url": "nats://nats.instanode.dev:4222",
  "subject_prefix": "tenant_a1b2c3d4....",
  "auth_mode": "isolated",
  "credentials": {
    "auth_mode": "isolated",
    "nats_jwt":  "<base64 user JWT>",
    "nats_nkey": "SUAA…",
    "creds_file": "-----BEGIN NATS USER JWT-----\n…",
    "key_id":   "ABBA…"
  }
}
```

Pass `(nats_jwt, nats_nkey)` to `nats.UserJWTAndSeed()` in the NATS Go client,
or write `creds_file` to disk and pass the path to `nats.UserCredentials()`.
When `auth_mode` is `"isolated"`, the tenant's JWT only permits pub/sub on the
`subject_prefix.*` namespace and cross-tenant publish is denied at the server.

> **Current production reality (read this).** Per-tenant account-JWT isolation
> is wired end-to-end but is **not yet active in production** — prod currently
> issues `auth_mode: "legacy_open"` for new queues (operator NKey generation is
> pending). In `legacy_open` there is **no `credentials` block and no
> server-side cross-tenant enforcement**: connect with just the
> `connection_url`, and treat the queue as shared-namespace — scope your own
> subjects under `subject_prefix.*` at the application layer. The `isolated`
> shape above is what you'll receive once isolation is enabled. Resources
> provisioned before the 2026-05-20 cutover are also `legacy_open`.

### Storage isolation mode (2026-05-20+)

The `/storage/new` response also includes a `mode` field that names the
isolation level the tenant landed on:

| mode | Meaning |
|---|---|
| `broker` | **DO Spaces today — what every new tenant receives.** No long-lived credential is issued; the response omits `access_key_id`/`secret_access_key`. Use `POST /storage/:token/presign` for short-lived signed URLs (max 1h TTL). |
| `shared-master-key` | Legacy DO Spaces rows only (pre-broker). Every tenant held the master key; isolation was by `prefix` convention. New tenants do NOT land here. |
| `prefix-scoped` | Backend IAM enforces `s3:prefix` against `<prefix>/*` (R2, S3, MinIO target). |
| `prefix-scoped-temporary` | Same as prefix-scoped but credentials are STS — they expire. |

The mode is decided at boot time by the `OBJECT_STORE_BACKEND` env var and
the backend's `Capabilities()`. Agents should branch on `mode` if they
need to behave differently — e.g. when `broker`, never try to write
directly with `(access_key_id, secret_access_key)` since the response
won't carry them.

### Broker-mode access: `POST /storage/{token}/presign`

When the `/storage/new` response carries `mode: "broker"`, no long-lived
credential was issued. Use this endpoint to mint a short-lived signed S3
URL (≤1h TTL) constrained to the resource's own `prefix/*`:

```
curl -X POST https://api.instanode.dev/storage/$TOKEN/presign \
  -H "Content-Type: application/json" \
  -d '{"operation":"PUT","key":"uploads/photo.jpg","expires_in":600}'
# => {"ok":true,"url":"https://s3.instanode.dev/...?X-Amz-Signature=...","expires_at":"..."}
```

- `operation` — `"PUT"` (upload) or `"GET"` (download)
- `key` — object key, will be prefixed with the resource's `<prefix>/`
  internally; the path is scoped so a signed URL cannot escape the
  prefix even if leaked
- `expires_in` — TTL in seconds, clamped to `[1, 3600]`; values ≤ 0 are
  rejected with `400 invalid_expires_in`

The URL is signed by the platform master key but enforces the
tenant's prefix at sign time, so leaked URLs cannot read or write other
tenants' objects. Rate-limited per token.

## Operational endpoints

- `GET /healthz` — shallow liveness probe. Returns 200 with `{ok, commit_id, build_time, version}` if the binary is up and can ping its primary platform DB. Use this to verify a deploy SHA matches what you pushed.
- `GET /readyz` — deep readiness probe (added 2026-05-20). Multi-component upstream-reachability matrix returning per-check status + latency + last_checked timestamp. Per-check criticality decides 200 vs 503. See [Deploying an app](/docs#deploy) for the full envelope shape.
- `POST /webhooks/brevo/:secret` — Brevo delivery webhook receiver (internal). Authenticated by URL token. Overwrites `forwarder_sent.classification` with the real outcome (`delivered`, `bounced_hard`, `bounced_soft`, `rejected`, `complaint`, `deferred`, `unsubscribed`, `error`) and stamps `delivered_at` on `delivered`. The truth surface for "did the user receive the email" — the worker's 201 from the Brevo API only means the relay accepted the POST; the ledger row's classification (set by this webhook) is the real outcome.

## Deploying an app

`POST /deploy/new` takes a multipart form with a gzipped tar archive
containing your Dockerfile + source.

```
curl -X POST https://api.instanode.dev/deploy/new \
  -H "Authorization: Bearer <JWT>" \
  -F "tarball=@app.tar.gz" \
  -F "name=expense-tracker" \
  -F "port=8080" \
  -F 'env_vars={"DATABASE_URL":"postgres://..."}'
```

`name` is **required** — it is the human-readable label for the deployment.
Send it as a form field. It must be 1–64 characters and match
`^[A-Za-z0-9][A-Za-z0-9 _-]*$` (start with a letter or digit; letters,
digits, spaces, underscores and hyphens after). Omitting it returns
`400 {"error":"name_required"}`; an invalid value returns
`400 {"error":"invalid_name"}`.

The build runs in-cluster on kaniko (~30–90s for typical Node/Python apps)
and the app rolls out behind a public HTTPS URL on
`*.deployment.instanode.dev` with a valid Let's Encrypt cert.

`env_vars` is optional — pass a JSON object and every key/value lands in
the app's environment on the first build. Saves you a follow-up PATCH+redeploy.

For multi-service apps see **Stacks** below.

## Deleting a deployment (paid tiers — two-step, email-confirmed)

Paid customers (Hobby, Hobby Plus, Pro, Growth, Team) can free a consumed
deployment slot at any time. Because deletion is destructive — every byte
of the running app + every env var — the agent CAN initiate but CANNOT
finalise destruction. Only the human, by clicking the email link, completes
the deletion.

### Step 1 — Initiate

```
curl -X DELETE https://api.instanode.dev/api/v1/deployments/<id> \
  -H "Authorization: Bearer $INSTANODE_TOKEN"
```

Response (HTTP 202):

```
{
  "ok": true,
  "id": "<deploy_id>",
  "deletion_status": "pending_confirmation",
  "confirmation_sent_to": "m***@instanode.dev",
  "confirmation_expires_at": "2026-05-14T10:30:00Z",
  "agent_action": "Tell the user to check their email at m***@instanode.dev. The deletion link expires in 15 minutes. To free the slot the user must click the link. The agent CANNOT confirm on the user's behalf — only the human can.",
  "cancellation_note": "Cancel by calling DELETE on the /confirm-deletion path, or let the 15-minute window expire."
}
```

The agent surfaces `agent_action` to the user verbatim. The slot stays
**consumed** until confirmation — a fresh `POST /deploy/new` still hits
the per-tier `deployments_apps` ceiling.

### Step 2 — User clicks the email link

The email link points at the API's `/auth/email/confirm-deletion?t=<token>`,
which 302s the user to the dashboard's `/app/confirm-deletion` page. The
dashboard runs the authenticated POST:

```
curl -X POST 'https://api.instanode.dev/api/v1/deployments/<id>/confirm-deletion?token=<plaintext>' \
  -H "Authorization: Bearer $INSTANODE_TOKEN"
```

Response (HTTP 200) → `deletion_status: "confirmed"`, slot is free.

### Cancel, expire, agent-override

- **Cancel** (user changes their mind): `DELETE /api/v1/deployments/<id>/confirm-deletion`. Resource stays active.
- **Expire** (15 minutes elapsed): the worker flips the row to `expired`. Re-running `DELETE` mints a fresh email.
- **Agent override**: set `X-Skip-Email-Confirmation: yes` on the original `DELETE` → 200 immediate destruction. Use only when the agent has obtained explicit user consent on its own side.

### Anonymous tier

Anonymous resources (24h TTL) have no email on file. `DELETE` returns
200 immediately — no two-step gate, since there is no inbox to mail.

### Stacks

Same contract applies to `DELETE /api/v1/stacks/<slug>`.

## Health and readiness probes

The platform exposes two distinct probes on every service (api, worker, provisioner):

- **`GET /healthz`** — shallow liveness. Returns 200 with `{ok, commit_id, build_time, version}` if the binary is up and can ping its primary platform DB. Wired to Kubernetes `livenessProbe`. Use this to verify a deploy actually rolled out (`commit_id` should match the git SHA you pushed).
- **`GET /readyz`** — deep readiness, added 2026-05-20. A multi-component matrix that walks every upstream the process depends on (platform_db, customer_db, redis-provision, provisioner_grpc, NATS, DO Spaces, Brevo, Razorpay, GeoIP). Per-check criticality decides the HTTP status: `platform_db` and `provisioner_grpc` are CRITICAL (a failed check returns 503 and pulls the pod from k8s rotation); everything else degrades to 200 with `overall=degraded` so a brevo outage degrades email but doesn't blackhole provisioning. Each check runs in parallel behind a 10-15s cache so the `readinessProbe` cycle doesn't self-DoS upstream rate limits.

Response envelope (same shape across all three services):

```json
{
  "ok": true,
  "overall": "ok",
  "commit_id": "abc1234",
  "checks": {
    "platform_db":      {"status": "ok",       "latency_ms":  4, "last_checked": "2026-05-20T..."},
    "provisioner_grpc": {"status": "ok",       "latency_ms": 12, "last_checked": "2026-05-20T..."},
    "brevo":            {"status": "degraded", "latency_ms": -1, "last_checked": "2026-05-20T...", "message": "brevo upstream timeout"}
  }
}
```

`overall` is the worst non-degraded status the criticality matrix permits to be surfaced. New Relic alert `readyz_degraded` fires on `overall != "ok"` for 5 consecutive minutes per service.

## Stacks (multi-service deploy)

`POST /stacks/new` takes an `instant.yaml` manifest plus one tarball per
service. Services can reference each other with `service://<name>` env
values — those resolve to cluster-internal `http://<name>:<port>` URLs at
deploy time.

The multipart form **requires** a `name` field — the human-readable label
for the stack. It must be 1–64 characters and match
`^[A-Za-z0-9][A-Za-z0-9 _-]*$` (start with a letter or digit; letters,
digits, spaces, underscores and hyphens after). Omitting it returns
`400 {"error":"name_required"}`; an invalid value returns
`400 {"error":"invalid_name"}`.

```
curl -X POST https://api.instanode.dev/stacks/new \
  -H "Authorization: Bearer <JWT>" \
  -F "name=shop-stack" \
  -F "manifest=@instant.yaml" \
  -F "api=@api.tar.gz" \
  -F "web=@web.tar.gz"
```

```
services:
  api:
    build: ./api
    port: 3000
  web:
    build: ./web
    port: 8080
    expose: true
    env:
      API_URL: service://api
```

Only services with `expose: true` get a public URL — the rest are
in-cluster only. The whole stack rolls out together; partial failure is
reported per-service in `GET /stacks/{slug}`.

## Debugging a failed deploy (for AI agents)

A deploy can fail at build (bad Dockerfile, missing file in the tarball,
dependency error) or roll out but crash at runtime. You do **not** need
cluster access to diagnose it — the platform classifies the failure and
serves the real error back to you over HTTP. This page is written for an
AI agent running a deploy → fix → redeploy loop.

## The auto-debug loop (authenticated deploys via `POST /deploy/new`)

When a deploy you started with `POST /deploy/new` ends up `failed`, run
this loop. The reliable machine surface is `GET /api/v1/deployments/:id/events` —
it is self-contained (reason + last_lines + hint) and needs only your
session token.

1. **Watch the build live (optional).** Stream the build log over SSE while
   it builds:

   ```
   curl -N https://api.instanode.dev/deploy/<id>/logs \
     -H "Authorization: Bearer $INSTANODE_TOKEN"
   ```

2. **Get the one-line status + summary.**

   ```
   curl https://api.instanode.dev/api/v1/deployments/<id> \
     -H "Authorization: Bearer $INSTANODE_TOKEN"
   ```

   Returns `status` (`building` / `failed` / `running` / `expired`) and,
   on failure, `error_message` — a `<reason>: <hint snippet>` summary
   (Kaniko error / ImagePullBackOff / BackoffLimitExceeded / DeadlineExceeded).

3. **Read the classified cause — the real error.** This is the surface to
   act on:

   ```
   curl https://api.instanode.dev/api/v1/deployments/<id>/events \
     -H "Authorization: Bearer $INSTANODE_TOKEN"
   ```

   Returns `{events, count}` where each event is:

   ```json
   {
     "kind": "failure_autopsy",
     "reason": "BackoffLimitExceeded",
     "exit_code": 1,
     "event": "...",
     "last_lines": ["...", "the tail of the build-pod log — the real error output"],
     "hint": "plain-language remedy",
     "created_at": "2026-06-06T..."
   }
   ```

   - `reason` — the classified failure class.
   - `last_lines` — the **tail of the build-pod logs**, the actual compiler /
     installer / Kaniko output that explains the failure. Read this first.
   - `hint` — a plain-language remedy for that reason.

4. **Fix it.** Edit the Dockerfile, the tarball contents, the `port`, or
   the `env_vars` per `hint` + `last_lines`. Common cases: a missing file
   that needed to be in the tar, a build step that needs a dependency, a
   wrong base image, an app that listens on a port other than the one you
   passed.

5. **Redeploy in place** (same `app_id`, same URL, slot count unchanged):

   ```
   curl -X POST https://api.instanode.dev/deploy/<id>/redeploy \
     -H "Authorization: Bearer $INSTANODE_TOKEN"
   ```

   Or pass `redeploy=true` on `POST /deploy/new` with the **same** `name`
   you used originally — the platform rebuilds the existing deployment in
   place and the response carries `"redeployed": true`. (Without
   `redeploy=true` a fresh `POST /deploy/new` mints a NEW app and a NEW
   URL, even when `name` collides.)

6. **Re-verify.** Poll `GET /api/v1/deployments/<id>` until `status` is
   `running` — or loop back to step 3 if it failed again.

## Anonymous deploys (via `POST /stacks/new`)

Anonymous (no-Bearer) callers cannot use `/deploy/new` — they deploy via
`POST /stacks/new` (anonymous stacks carry no team and expire after a 6h
TTL). The failure-diagnosis path for an anonymous stack is **thinner**:

1. **Status + raw error.** Read the stack by its slug (no auth needed —
   the slug is the bearer):

   ```
   curl https://api.instanode.dev/api/v1/stacks/<slug>
   ```

   On failure this returns `status="failed"` plus the raw error string.

2. **Per-service build logs.**

   ```
   curl https://api.instanode.dev/stacks/<slug>/logs/<service>
   ```

Anonymous stacks do **not** have the classified `/events` autopsy
(`reason` / `last_lines` / `hint`) — there is no `/stacks/:slug/events`
endpoint. That is a known thinner path: anonymous deploys get **status +
raw error + logs**, not the classified autopsy. Claim/upgrade to deploy
via `/deploy/new` for the full debug surface.

## Caveats (read these — they affect how you diagnose)

- **Don't rely on the failure email.** A `failed` deploy records a failure
  notification, but transactional email delivery is currently blocked (the
  sender domain isn't validated in prod), so the email may not reach a real
  inbox. Use `GET /api/v1/deployments/:id/events` and the dashboard
  failure-autopsy panel as the source of truth, not email.
- **"Diagnostics pending" window.** For a few seconds right after a
  failure the autopsy is still capturing the build-pod logs — `/events`
  may be empty or carry `reason="Unknown"`. Wait a moment and re-poll.
- **Runtime crash-loops are thinner than build failures.** A deploy that
  *builds* fine but crash-loops at runtime (CrashLoopBackOff, OOMKilled,
  readiness-probe failure) has less customer-facing diagnostics today than
  the build-failure autopsy. Build-failure diagnosis is the
  well-instrumented path; deeper runtime crash-loop visibility is a known
  follow-up.

## Surfaces at a glance

| Surface | What it gives you |
| --- | --- |
| `GET /api/v1/deployments/:id` | `status` + one-line `error_message` |
| `GET /api/v1/deployments/:id/events` | classified `reason` + `last_lines` + `hint` (the real error — use this) |
| `GET /deploy/:id/logs` | live build log stream (SSE) |
| `GET /api/v1/stacks/:slug` | anonymous-stack `status` + raw error string |
| `GET /stacks/:slug/logs/:svc` | anonymous-stack per-service build logs |

## Claim flow (anonymous → paid)

Anonymous resources expire in 24 hours. To keep them, claim them.

```
RESP=$(curl -X POST https://api.instanode.dev/db/new \
  -H "Content-Type: application/json" \
  -d '{"name":"prod-db"}')
JWT=$(echo $RESP | jq -r .upgrade_jwt)

# Optional preview — shows what would attach, no side effects
curl "https://api.instanode.dev/claim/preview?t=$JWT"

# Trigger the claim — sends a magic link to your email
curl -X POST https://api.instanode.dev/claim \
  -d "{\"jwt\":\"$JWT\", \"email\":\"you@example.com\"}"
```

Click the magic link to set a session cookie. Every resource attached to your
fingerprint transfers to your team atomically; the connection URLs don't
change so any already-running code keeps working.

Claimed resources move to your team's **Free tier** (24h TTL, same limits as
anonymous) — claiming gives you an account, not durability. Resources keep
expiring at 24 hours until you upgrade to a paid tier (Hobby $9/mo or above)
in the dashboard. Paid tiers bill from day one — there is no separate trial
period.

## Authentication

Resource provisioning is anonymous. Everything else (deploy, vault, billing,
team management) requires a session JWT.

How to get one:

1. Provision any resource anonymously. The response includes a JWT in the
   `upgrade_jwt` field.
2. POST that JWT to /claim with an email. We send a magic link.
3. Click the link in the email; the page sets a session cookie.

For unattended use (CI, agents), exchange the session cookie for a long-lived
API key at `POST /api/v1/auth/api-keys`. Pass it as `Authorization: Bearer
<key>` on every request.

To verify a token works at any time, hit `GET /api/v1/whoami` — returns
200 with your team_id + plan_tier on success, 401 on failure.

## Tiers and limits

| Tier       | Postgres    | Redis     | MongoDB      | TTL  | Price       |
| ---------- | ----------- | --------- | ------------ | ---- | ----------- |
| Anonymous  | 10MB / 2c   | 5MB       | 5MB / 2c     | 24h  | free        |
| Hobby      | 1GB / 8c    | 50MB      | 100MB / 5c   | none | $9 / mo     |
| Pro        | 10GB / 20c  | 512MB     | 5GB / 20c    | none | $49 / mo    |
| Team       | 50GB / 100c | 1.5GB     | 40GB / 50c   | none | $199 / mo*  |

"c" = simultaneous connections. The full table is at `/pricing`.

Hobby Plus and Growth exist in `plans.yaml` as upsell-only intermediate tiers
reached via in-dashboard prompts when a Hobby user hits a quota wall. They are
deliberately omitted from the public tier ladder to keep the customer-facing
comparison simple.

**Team tier status (\*):** Team is **launching soon — not yet self-serve**. It
cannot be purchased or claimed today; `POST /api/v1/billing/checkout` and
`/change-plan` reject `plan=team`. Contact contact@instanode.dev for onboarding.
When it ships, Team is planned at $199/mo with high finite limits (not unlimited):
50 GB Postgres / 100 connections, 1.5 GB Redis, 40 GB MongoDB / 50 connections,
40 GB queues, 300 GB object storage, 30 GB vector, 100 deployment apps, 1000 vault
entries, 100k webhooks, 50 custom domains, 90-day backups with self-serve restore
(backups cover Postgres, pgvector, MongoDB & Redis; restore is self-serve for
Postgres/pgvector/MongoDB — Redis is backup-only today, restore coming soon),
and RBAC + audit log. Capacity beyond these caps (or dedicated/isolated infra,
multi-region, or compliance such as SOC2/BAA/SSO/SLA/DPA) is Enterprise — contact
sales@instanode.dev.

Note: self-serve checkout for the live paid tiers (Hobby/Pro) currently depends on
the Razorpay recurring-billing rollout — until that operator step completes,
`POST /api/v1/billing/checkout` may return a `502`/`503`; contact
contact@instanode.dev for assisted onboarding in the meantime.

Limits are enforced at the Postgres user level (`CONNECTION LIMIT` on the
role) and via per-bucket storage quotas. Exceeding a limit returns a 402 with
an upgrade URL — your app keeps running, the next provision just fails.

## `POST /api/v1/billing/checkout` — concurrent-call dedup

`POST /api/v1/billing/checkout` is server-side deduplicated per team. A second
concurrent call for the same team — within a 60s window — gets a structured
409 instead of a second Razorpay subscription. This catches cross-tab clicks,
mobile double-taps, retried form submits, and agents that retry the endpoint
without coordination.

Response envelope:

```json
{
  "ok": false,
  "error": "checkout_in_flight",
  "message": "A checkout is already being created for this team. Wait ~60s and retry, or visit /dashboard to find the existing pending subscription.",
  "retry_after_seconds": 60,
  "agent_action": "Tell the user a checkout is already being created. They should wait ~60 seconds and refresh — the existing checkout link will appear in the dashboard.",
  "request_id": "..."
}
```

The `retry_after_seconds` field tells callers how long to wait. The TTL also
caps the worst case where the first caller crashes mid-flight — after 60s a
retry is allowed automatically. The standard `Idempotency-Key` header (see
`/docs/idempotency`) is honoured on this route too and provides a longer-window
guarantee — pass it on every retry of a logical checkout attempt.

If Redis is unavailable the dedup guard fails open (the call proceeds), with
a `WARN billing.checkout.dedup_setnx_failed_open` log line. A Redis brownout
must never block a paid upgrade — the idempotency middleware is the second
layer of defence.

## Machine-readable API

The full API surface is described in OpenAPI 3.1 at:

```
https://api.instanode.dev/openapi.json
```

It is the source of truth for paths, schemas, security schemes, and which
endpoints accept anonymous traffic. Agents reading this spec alone can
discover the claim flow (described under `securitySchemes.bearerAuth`),
the `/api/v1/whoami` identity probe, and which fields like `upgrade_jwt`
to pass forward.

If you're an AI agent reading this, the recommended bootstrap is:

1. `GET /openapi.json`
2. Provision anonymous resources
3. `GET /api/v1/whoami` to confirm token validity once you have one

