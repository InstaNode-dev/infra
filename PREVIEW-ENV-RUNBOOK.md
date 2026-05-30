# Preview-Env Runbook — Per-PR Ephemeral k8s Environments

> This runbook covers Phase 1a (scaffolding) of the Layer-3 per-PR preview
> system designed in `/tmp/LAYER-3-EPHEMERAL-K8S-DESIGN.md` (mirror-pasted
> into the infra repo on merge). Phases 1b + 1c are listed at the bottom
> with effort estimates and follow once the operator confirms the Phase 1a
> RBAC + DNS prereqs.

## What Phase 1a ships

Scaffolding only. **No real preview namespace is created in Phase 1a.**
The CI plumbing fires end-to-end, every workflow echoes what it would do,
and a `neutral` (warn-only) check appears on every api PR. This deliberate
dry-run period proves the dispatch + check-run + RBAC paths are wired
correctly before any real cluster mutation is enabled.

Files added:

| Path | Purpose |
|---|---|
| `k8s/preview/00-rbac.yaml` | `preview-system` namespace, `preview-provisioner` SA, ClusterRoles for namespace lifecycle + per-namespace editor verbs |
| `k8s/preview/02-policies.yaml` | Kyverno ClusterPolicy that REJECTS any namespace create by `preview-provisioner` unless the name starts with `preview-api-pr-` (and requires the `instanode.dev/preview-pr` label) |
| `k8s/preview/10-quota-template.yaml` | ResourceQuota (2 CPU / 4 GiB RAM / 8 GiB ephemeral / 20 pods) + LimitRange (200m/256Mi default request, 400m/512Mi default limit) per preview namespace. Templated; `envsubst`'d at provision time |
| `k8s/preview/20-cron-ttl.yaml` | CronJob in `preview-system` that scans every 6h for `preview-api-pr-*` namespaces older than 72h. **Phase 1a runs DRY-RUN ONLY** (`DRY_RUN=true`) — logs "WOULD DELETE" lines but never deletes |
| `.github/workflows/preview-create.yml` | Listens for `repository_dispatch:preview-create-from-api`, validates inputs, posts a `neutral` check-run on the api PR (no kubectl in Phase 1a) |
| `.github/workflows/preview-teardown.yml` | Listens for `repository_dispatch:preview-teardown-from-api`, dry-run logs the namespace it would delete |

Companion (in the `api` repo, separate PR):

| Path | Purpose |
|---|---|
| `.github/workflows/preview-dispatch.yml` | Fires `preview-create-from-api` on PR open/sync/reopen, `preview-teardown-from-api` on PR close. Uses the existing `REPO_ACCESS_TOKEN` secret |

## Phase 1a operator setup

> Order matters — RBAC before policies before CronJob, otherwise apply
> fails on missing dependencies.

```bash
# 0. Confirm context — Phase 1a applies to the shared prod cluster
kubectl config current-context
# Expected: do-nyc3-instant-prod

# 1. (Prereq, if not already on cluster) Install Kyverno for the name-prefix
#    guard in 02-policies.yaml. Skip if already installed.
kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 || \
  kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
# Wait for kyverno pods to be Ready before applying 02-policies.yaml:
kubectl -n kyverno wait --for=condition=Available --timeout=300s deploy --all

# 2. Apply RBAC + policies + TTL CronJob
kubectl apply -f k8s/preview/00-rbac.yaml
kubectl apply -f k8s/preview/02-policies.yaml
kubectl apply -f k8s/preview/20-cron-ttl.yaml

# 3. Verify the SA can do what it needs to
kubectl auth can-i create namespaces \
  --as=system:serviceaccount:preview-system:preview-provisioner
# Expected: yes

kubectl auth can-i create deployments \
  --as=system:serviceaccount:preview-system:preview-provisioner \
  -n preview-api-pr-1
# Expected: yes  (the ns doesn't have to exist for auth check)

# 4. Verify Kyverno's name-prefix guard fires (negative test)
cat <<'EOF' | kubectl apply --as=system:serviceaccount:preview-system:preview-provisioner -f -
apiVersion: v1
kind: Namespace
metadata:
  name: should-be-rejected
  labels:
    instanode.dev/preview-pr: "999"
EOF
# Expected: error from server (validate.kyverno.io): admission webhook denied the request:
#   Namespaces created by preview-provisioner must be named preview-api-pr-<PR_NUMBER>.

# 5. Mint a kubeconfig for the SA and base64-encode it for GH Actions
kubectl create token preview-provisioner -n preview-system --duration=8760h \
  > /tmp/preview-token
# Build a scoped kubeconfig (cluster URL + CA cert + token) and base64 it.
# Example (adapt cluster URL + CA from your existing prod kubeconfig):
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
cat > /tmp/preview-kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: instanode-prod
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
contexts:
  - name: preview-provisioner@instanode-prod
    context:
      cluster: instanode-prod
      namespace: preview-system
      user: preview-provisioner
current-context: preview-provisioner@instanode-prod
users:
  - name: preview-provisioner
    user:
      token: $(cat /tmp/preview-token)
EOF
base64 -w0 < /tmp/preview-kubeconfig.yaml > /tmp/preview-kubeconfig.b64

# 6. Add to GitHub Actions on the infra repo
gh secret set PREVIEW_KUBECONFIG_B64 --repo InstaNode-dev/infra < /tmp/preview-kubeconfig.b64
shred -u /tmp/preview-token /tmp/preview-kubeconfig.yaml /tmp/preview-kubeconfig.b64

# 7. Mint a fine-grained PAT with `checks: write` on InstaNode-dev/api and
#    save it as PREVIEW_CHECKS_TOKEN on the infra repo. The default
#    GITHUB_TOKEN cannot post check-runs to a different repo.
#    https://github.com/settings/personal-access-tokens/new
gh secret set PREVIEW_CHECKS_TOKEN --repo InstaNode-dev/infra
```

## Outstanding operator tasks that gate Phase 1b

These MUST be cleared before Phase 1b can wire actual provisioning. Phase
1a is fully shippable without them — the dry-run workflows still validate
the dispatch + check-run path end-to-end.

1. **Wildcard DNS at Cloudflare.** Add an A-record:
   ```
   *.preview.instanode.dev   →   <load-balancer-IP>
   ```
   The LB IP is the same one `*.deployment.instanode.dev` already points to
   (the shared cluster ingress). Confirm with:
   ```
   dig +short *.deployment.instanode.dev @1.1.1.1
   ```
   Then add the `*.preview.instanode.dev` A-record to the same IP in the
   Cloudflare dashboard. TTL: 300s. Proxy: DNS-only (orange-cloud OFF) —
   the ingress controller handles TLS termination via cert-manager.

2. **cert-manager DNS-01 ClusterIssuer.** Confirm an issuer named
   `letsencrypt-preview-dns01` exists, OR document that it needs to be
   created. HTTP-01 challenges don't work for wildcard certs; DNS-01 is
   required. Check with:
   ```
   kubectl get clusterissuer letsencrypt-preview-dns01 -o yaml
   ```
   If it doesn't exist, the operator creates it using the existing
   Cloudflare API token in `cert-manager` ns (same token used by the
   `*.deployment.instanode.dev` issuer). Spec template lives in
   `k8s/cert-manager/` once created.

## Verification (Phase 1a)

After merge + operator applies steps above, fire a test dispatch from the
infra repo to prove the wiring:

```bash
gh workflow run preview-create.yml \
  --repo InstaNode-dev/infra \
  -f api_pr=1 \
  -f api_sha=abc1234
```

Expected output in the workflow logs:
- Input validation passes (`inputs OK: api_pr=1 api_sha=abc1234`)
- `Would create namespace: preview-api-pr-1`
- Rendered ResourceQuota + LimitRange YAML printed
- A `neutral` check-run posted to `InstaNode-dev/api` for SHA `abc1234`
  (visible on the PR matching that SHA, or under the repo's Checks tab if
  no PR exists for the test SHA)

Then verify the TTL CronJob:

```bash
kubectl create job --from=cronjob/preview-ttl-sweeper preview-ttl-sweeper-manual -n preview-system
kubectl logs -n preview-system job/preview-ttl-sweeper-manual
```

Expected output (no preview namespaces exist yet, dry-run mode):
```
preview-ttl-sweeper start (dry_run=true, max_age_hours=72)
preview-ttl-sweeper done: found=0 swept=0 ...
```

## Phase 1b — what's wired (this PR)

Real provisioning lands in the same workflows. Files added/updated:

| Path | Change |
|---|---|
| `.github/workflows/preview-create.yml` | Decodes `PREVIEW_KUBECONFIG_B64`, creates `preview-api-pr-<N>` namespace, applies ResourceQuota + LimitRange + pg-platform sidecar + api Deployment/Service/Ingress, waits for rollout (240s), posts `success` (or `neutral` on soft-fail) check on the api PR. **Soft-fails (warn-only check, exit 0) when `PREVIEW_KUBECONFIG_B64` is unset** so this PR can merge dormant. |
| `.github/workflows/preview-teardown.yml` | Decodes kubeconfig, `kubectl delete namespace preview-api-pr-<N>` (cascade), posts teardown check on the api PR. Same soft-fail on missing kubeconfig. |
| `k8s/preview/20-cron-ttl.yaml` | `DRY_RUN=true` → `DRY_RUN=false`. Real deletes after 72h. |
| `k8s/preview/30-data-template.yaml` | NEW — slim single-replica pg-platform Deployment + Service + Secret. `emptyDir`-backed, no PVC. ${PREVIEW_NS}/${PR_NUMBER}/${PG_PASSWORD} substituted at apply time. |
| `k8s/preview/40-api-template.yaml` | NEW — api Deployment (image `:pr-<N>-<sha>` from GHCR, initContainer = pg-platform wait), Service, Ingress for `pr-<N>.preview.instanode.dev`. Per-preview JWT + AES + pg password generated at provision time, never reused, never the prod values. |

Scope is deliberately small for Phase 1b — only api + pg-platform. No worker, no provisioner, no Mongo, no Redis, no NATS. Endpoints that need those will 503 in preview; Phase 1c adds them.

Companion api PR: `feat/preview-env-pr-image-retag` adds the `:pr-<N>-<sha>` tag push to api/.github/workflows/deploy.yml so the preview workflow has an image to deploy.

## Phase 1b — operator activation (once your prerequisites land)

Once the two Phase 1a operator tasks below (DNS + cert-manager) are done AND `PREVIEW_KUBECONFIG_B64` + `PREVIEW_CHECKS_TOKEN` are set on the infra repo, the workflow auto-fires on every api PR — no further toggle needed. Verify with:

```bash
# 1. Confirm the secret is on the infra repo
gh secret list --repo InstaNode-dev/infra | grep -E 'PREVIEW_KUBECONFIG_B64|PREVIEW_CHECKS_TOKEN'
# Expected: both listed

# 2. Manually fire preview-create against a known PR + SHA
gh workflow run preview-create.yml \
  --repo InstaNode-dev/infra \
  -f api_pr=210 \
  -f api_sha=7cefafb

# 3. Wait for the workflow, then check the namespace + the api PR's
#    Checks tab. On success you should see:
kubectl get ns preview-api-pr-210
kubectl get deploy,svc,ing -n preview-api-pr-210
curl -k https://pr-210.preview.instanode.dev/healthz

# 4. Tear it down
gh workflow run preview-teardown.yml \
  --repo InstaNode-dev/infra \
  -f api_pr=210
kubectl get ns preview-api-pr-210
# Expected: not found (or Terminating)
```

Optional belt-and-suspenders: copy the GHCR pull Secret to `preview-system` and adjust `preview-create.yml`'s copy step source ns if you'd rather not grant the preview SA `get secrets` in `instant`.

## Next phases

| Phase | Scope | Effort |
|---|---|---|
| **1c** | Wait for `/healthz` on the preview URL to report `commit_id == PR head SHA` (rule 14 gate). Run Playwright suite vs preview URL. Add pg-customers + redis + worker + provisioner to the preview env so `/db/new` / `/cache/new` / async jobs work. Post `success`/`failure` check-runs (still `neutral` for first month, then promote per warn-only month-1 decision). | 3 days |
| **2** | Multi-repo: worker + provisioner PRs trigger preview env with their own image tag. Cross-origin auth tests with `app.<slug>` + `api.<slug>`. | 3 days |

## Promotion criterion (warn-only → blocking)

Per operator decision: the `preview-env` check stays `neutral` (warn-only)
for the first **30 days** OR until **200 PR runs** complete with **flake
rate < 2%**, whichever is later. Flake = preview env fails to come up
OR `/healthz` doesn't report the expected SHA OR Playwright times out,
WHEN re-running the same workflow succeeds. Track via the dispatched
check-run history on a dashboard tile (Phase 1c includes the New Relic
tile per rule 25).

## Hard rules

1. **Never `kubectl apply -f k8s/preview/` to the wrong cluster.** This
   directory targets `do-nyc3-instant-prod` (the shared cluster Layer 3
   piggybacks on). Confirm context first, every time.
2. **Never grant the preview SA `cluster-admin`.** The narrow ClusterRoles
   in `00-rbac.yaml` are the entire surface — adding `cluster-admin`
   defeats the Kyverno guard and exposes the prod data tier.
3. **Preview namespaces NEVER reference `instant-data` Services.** The
   design doc §5 paranoia check: a preview's `CUSTOMER_DATABASE_URL` MUST
   point to its in-namespace pg-customers Service, NEVER the prod pod in
   `instant-data`. Phase 1b workflow will grep the rendered manifest for
   any `instant-data` cross-ns reference and abort if found.
4. **`OBJECT_STORE_BACKEND=minio` + `BREVO_API_KEY=` empty in preview.**
   Preview envs MUST NOT use real DO Spaces / real Brevo creds. Compromise
   of a preview namespace must not expose prod credentials.

## Related files

- `/tmp/LAYER-3-EPHEMERAL-K8S-DESIGN.md` — the design doc this implements
- `infra/k8s/APPLY-CHECKLIST.md` — apply rules for prod manifests (see new
  "Preview-env subdir" paragraph)
- `CLAUDE.md` rule 25 — every new metric ships with its alert + dashboard
  tile in the same PR (applies to the Phase 1c preview-env metrics)
- `api/.github/workflows/preview-dispatch.yml` — the api-side trigger
