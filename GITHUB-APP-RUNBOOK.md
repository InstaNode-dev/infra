# GitHub App Runbook (P4 — push-to-deploy)

Operator steps to register the **InstaNode** GitHub App and flip the feature on.
The application code (install flow, token minter, install↔team model) ships
flag-gated OFF (`GITHUB_APP_ENABLED=false`) — this runbook is what turns it on.
Until then, `GET /integrations/github/{install,callback}` return 501
`github_app_disabled` and the manual per-repo webhook
(`POST /api/v1/deployments/:id/github`) + `source=git` with a token remain the
supported paths.

---

## 1. Register the App (one-time, GitHub UI)

GitHub → **Settings → Developer settings → GitHub Apps → New GitHub App**.

| Field | Value |
|---|---|
| GitHub App name | `InstaNode` (the slug becomes `instanode` — note it) |
| Homepage URL | `https://instanode.dev` |
| **Callback URL** | `https://api.instanode.dev/integrations/github/callback` |
| **Webhook URL** | `https://api.instanode.dev/webhooks/github` (P4.2) |
| Webhook secret | generate a strong random secret — save it |
| Webhook | **Active** ✓ |

**Permissions** (Repository):
- **Contents: Read-only** (clone the repo for the build)
- **Metadata: Read-only** (mandatory)
- *(P4.3 optional)* **Checks: Read & write** (post build status back to the commit)

**Subscribe to events:** `Push`, `Installation`, `Installation repositories`.

**Where can this App be installed?** "Any account" (public) once vetted; "Only on
this account" while testing.

After creation:
- Note the **App ID** (numeric) and the **public slug** (from the App's URL
  `github.com/apps/<slug>`).
- **Generate a private key** → downloads a `.pem` (PKCS#1 RSA). This is the
  highest-value secret — it can mint installation tokens for *every* install.
- Note the **Client ID** and generate a **Client secret**.

## 2. Provision the secrets (k8s — NOT ConfigMap, NOT the repo)

```bash
kubectl -n instant create secret generic instant-github-app \
  --from-literal=GITHUB_APP_ID='<app-id>' \
  --from-literal=GITHUB_APP_SLUG='instanode' \
  --from-literal=GITHUB_APP_WEBHOOK_SECRET='<webhook-secret>' \
  --from-literal=GITHUB_APP_CLIENT_ID='<client-id>' \
  --from-literal=GITHUB_APP_CLIENT_SECRET='<client-secret>' \
  --from-file=GITHUB_APP_PRIVATE_KEY=/path/to/instanode.<date>.private-key.pem
```

Wire them into the `instant-api` (and, for P4.2, `instant-worker`) Deployments as
env from the secret. **Never** put the private key in `instant-config` (the
ConfigMap) or commit it. Rotation: generate a new private key in the App
settings, update the secret, `kubectl rollout restart deploy/instant-api`, then
delete the old key in GitHub.

## 3. Flip the flag (canary)

> **Pre-flag-flip hardening (REQUIRED before broad/public rollout).** P4.1/P4.2
> ship two known residual gaps from the security review, safe while flag-OFF but
> must be closed before the App is publicly installable:
> 1. **Full installation-ownership verification** (review HIGH-2 residual). The
>    callback's upsert is WHERE-guarded so it can't *rebind* an existing
>    installation to another team, but a first-writer race (attacker calls the
>    callback with a known installation_id before the victim's own callback)
>    is still theoretically possible. Close it by exchanging the install-flow
>    `code` for a user-to-server token and confirming the installation belongs
>    to the authenticating GitHub user (lands with the P4.3 dashboard OAuth flow).
> 2. **Worker dispatch guard** (review MED-2). `pending_github_deploys` rows
>    already queued are not re-checked against `github_installations` before the
>    worker dispatches them, so a deploy enqueued ~seconds before a
>    suspend/delete can still run. Add a `JOIN github_installations` (filter
>    `suspended_at IS NULL`) to the worker's `claimBatch`, OR cancel queued rows
>    in the installation webhook. Worker-repo change.

```bash
kubectl -n instant set env deploy/instant-api GITHUB_APP_ENABLED=true
kubectl -n instant rollout status deploy/instant-api
```

Verify: `GET https://api.instanode.dev/integrations/github/install` with a valid
session Bearer should now **302** to `github.com/apps/instanode/installations/new`
(instead of 501). Install on a test repo and confirm a row lands in
`github_installations` (callback persists it).

## 4. Rollback

`kubectl -n instant set env deploy/instant-api GITHUB_APP_ENABLED-` (unset) →
the endpoints return 501 again; no data is destroyed (`github_installations`
rows are harmless when the feature is off).

---

## Security notes

- **Private key** mints tokens for all installations → k8s secret only; audit
  access; rotate on any suspicion.
- The App webhook (P4.2) is HMAC-verified (`X-Hub-Signature-256`) against
  `GITHUB_APP_WEBHOOK_SECRET`; an incoming push's `(installation_id, repo)` is
  matched against a persisted `github_installations` link before any deploy —
  the payload is never trusted on its own.
- Installation access tokens are minted on demand (`contents:read`, ~1h TTL),
  cached in Redis ~55 min, and **never persisted at rest**.
- `git_url` host is still SSRF-screened and the build-pod egress NetworkPolicy
  backstop applies (see P3).

## Phase status

- **P4.1 (this change):** install/callback flow + `github_installations` + token
  minter (`internal/github`). Flag-gated OFF. Live verification needs §1–§3.
- **P4.2 (next):** `POST /webhooks/github` (App webhook) → push → auto in-place
  redeploy; installation token wired into the `source=git` clone path;
  installation lifecycle (suspend/delete) sync.
- **P4.3:** dashboard "Connect GitHub" UI + contract sync (openapi/llms/MCP) +
  metrics/alerts + optional Checks-API status.
