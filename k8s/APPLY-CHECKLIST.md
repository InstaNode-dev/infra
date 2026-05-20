# Apply Checklist — Deployment Manifests

> Codified 2026-05-20 after a near-miss where applying the repo's
> `app.yaml` would have stripped `imagePullSecrets`, reset the image to
> `instant-api:local`, and added a `wait-for-platform-db` init container
> that blocks forever in prod. See "What went wrong" at the bottom.

This checklist applies to:

- `infra/k8s/app.yaml` — `Deployment/instant-api` in namespace `instant`
- `infra/k8s/worker/deployment.yaml` — `Deployment/instant-worker` in `instant-infra`
- `infra/k8s/provisioner/deployment.yaml` — `Deployment/instant-provisioner` in `instant-infra`

Per CLAUDE.md rule 15: **this repo has no auto-apply by design.** Manifest
apply is a deliberate, human-driven step.

---

## Hard rules

1. **DO NOT `kubectl apply -f k8s/app.yaml` against prod without first
   running `kubectl apply --dry-run=server` and reading the diff line by
   line.** The dry-run reveals exactly what the apply will change. If the
   diff includes anything other than the image tag, STOP and investigate.

2. **`imagePullSecrets` MUST be present** on every deployment manifest:

   | Deployment | Required secrets |
   |---|---|
   | `instant-api` | `ghcr-pull`, `ghcr-org-pull` |
   | `instant-worker` | `ghcr-pull`, `ghcr-regrade` |
   | `instant-provisioner` | `ghcr-pull`, `ghcr-regrade` |

   Without these, new pods land in `ImagePullBackOff`. The auto-deploy CI
   (which sets the image via `kubectl set image`) cannot repair stripped
   `imagePullSecrets` — it only touches the image field.

3. **The image tag in this file is a placeholder.** The actual prod image
   is set by the per-service auto-deploy CI in the api/worker/provisioner
   repos via:

   ```
   kubectl set image deploy/<name> <container>=ghcr.io/instanode-dev/<image>:master-<sha>
   ```

   The placeholder `:placeholder` is intentional — if a literal apply
   ever reaches prod, the pull will fail loudly (`ErrImagePull`) instead
   of silently regressing to a stale image. Loud failure > silent regression.

4. **Init containers that reference in-cluster services that don't
   exist in prod are removed from the base manifest.** The legacy
   `wait-for-platform-db` (and provisioner's `wait-for-provisioner-db`)
   init containers expected an in-cluster `postgres-platform` /
   `postgres-provisioner` Service. Prod uses DigitalOcean Managed
   Postgres — those Services do not exist. Init containers would block
   pod startup indefinitely.

   For local dev (Rancher Desktop / k3s with an in-cluster postgres pod),
   layer a kustomize overlay or just patch the init container in by hand:

   ```
   kubectl patch deploy/instant-api -n instant --type=json -p='[
     {"op":"add","path":"/spec/template/spec/initContainers","value":[
       {"name":"wait-for-platform-db","image":"postgres:16-alpine",
        "command":["sh","-c","until pg_isready -h postgres-platform -U instant -d instant_platform; do sleep 2; done"]}
     ]}
   ]'
   ```

5. **`terminationGracePeriodSeconds`, `lifecycle.preStop`, and graceful-
   shutdown probes must stay codified** (MR-P0-7, 2026-05-20). The api
   needs 35s (5s preStop + 3s readiness drain + 25s Fiber drain + 2s
   buffer) — anything less and k8s SIGKILLs mid-drain. The worker drains
   River jobs in `Workers.Stop` (MR-P0-2/P1-3) and needs the default 30s.

6. **`E2E_TEST_TOKEN` is declared ONCE on `instant-api`.** Earlier live
   manifests had two `env[E2E_TEST_TOKEN]` entries — kubectl raised a
   `hides previous definition` warning. The repo manifest declares it
   exactly once with `optional: true`.

---

## Standard pre-apply procedure

```bash
# 1. Confirm context
kubectl config current-context
# Expected: do-nyc3-instant-prod (for prod) or rancher-desktop (for local)

# 2. Dry-run server-side (validates against the real API server, surfaces
#    schema errors AND shows what would change without changing anything)
kubectl apply --dry-run=server -f k8s/app.yaml

# 3. Diff against live (this is the SOURCE OF TRUTH for what apply will do)
diff <(kubectl apply --dry-run=server -f k8s/app.yaml -o yaml 2>/dev/null) \
     <(kubectl get deploy/instant-api -n instant -o yaml)

# 4. Read every line of the diff. Acceptable drift:
#    - image tag (will be overwritten by the next auto-deploy CI run)
#    - status block (read-only, computed by the controller)
#    - metadata.resourceVersion, generation (managed by the API server)
#    Anything else → STOP, investigate.

# 5. If the diff is clean, apply
kubectl apply -f k8s/app.yaml

# 6. After apply, immediately re-trigger the auto-deploy CI in the
#    api/worker/provisioner repo (or `kubectl set image` manually) to
#    restore the real image tag.
```

---

## What goes in the manifest vs the cluster

The manifest is the **structural** source of truth: deployment shape,
container names, env var declarations (with `valueFrom` references),
probes, resource limits, imagePullSecrets, volumeMounts.

The cluster is the **value** source of truth for secrets and the
current image tag:

- All `secretKeyRef`-resolved env vars get their values from
  `instant-secrets` / `instant-infra-secrets` (live in the cluster, NOT
  in this repo — see `secrets.yaml` template warning in `README.md`).
- The image tag is owned by the per-service auto-deploy CI on push to
  master in each backend repo.

If you add a new `secretKeyRef` env var here, you must ALSO
`kubectl patch secret instant-secrets ...` (or `instant-infra-secrets`)
with the real value — the manifest only declares the reference, it
doesn't seed the secret.

---

## What went wrong (2026-05-20 near-miss)

The repo's `app.yaml` had drifted away from live prod over several
weeks of incremental `kubectl patch` and `kubectl set image` operations
that never made it back into the file:

| Drift | Repo before fix | Live |
|---|---|---|
| `imagePullSecrets` | absent | `ghcr-pull`, `ghcr-org-pull` |
| Container image | `instant-api:local` | `ghcr.io/instanode-dev/instant-api:master-<sha>` |
| `wait-for-platform-db` initContainer | present | absent (DO Managed Postgres) |
| `OTEL_EXPORTER_OTLP_HEADERS` env | absent | present (NR license key) |
| `BUILD_IMAGE_REGISTRY` / `DEPLOY_DOMAIN` / `CERT_ISSUER` env | absent | present |
| `RAZORPAY_PLAN_ID_*_YEARLY` env | absent | present |
| `OBJECT_STORE_*` env (7 keys) | absent | present |
| `GITHUB_CLIENT_ID` / `GOOGLE_CLIENT_ID` env | absent | present |
| `E2E_TEST_TOKEN` env | absent (live had 2 — duplication warning) | present (deduped here, optional: true) |

A naive `kubectl apply -f k8s/app.yaml` would have:

1. Stripped `imagePullSecrets` → new pods stuck in `ImagePullBackOff`
2. Reset image to `instant-api:local` → ImagePullBackOff (no such image)
3. Added the `wait-for-platform-db` init container → pod blocks forever
   waiting for an in-cluster service that doesn't exist
4. Dropped ~15 env vars → api boots but immediately fails on missing
   Razorpay annual plans, object-store creds, OAuth client IDs, OTLP
   headers, etc.

That is, three independent failure modes per pod. With `replicas: 2` and
rolling update, that's enough to wipe the api fleet within a minute.

The fix codifies the live state. The placeholder image tag (`:placeholder`)
guarantees that a future naive apply fails loudly (`ErrImagePull`) instead
of silently regressing.

---

## Related files

- `README.md` — secrets clobber warning (the same class of bug, but for
  the `secrets.yaml` template)
- `scripts/safe-secret-apply.sh` — runtime guardrail against
  `CHANGE_ME`-clobbering applies of secret YAMLs
- `docs/IMAGE-RETENTION-POLICY.md` — image pinning and retention policy
  referenced by the `instanode.dev/image-pinned` labels
- `apply-all.sh` — the bootstrap script (intended for fresh clusters,
  NOT for in-place prod updates)
