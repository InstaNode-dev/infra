# Image Retention Policy

**Status:** active as of 2026-05-13
**Owner:** infra
**Scope:** every container image pushed to `ghcr.io/instanode-dev/*`

## Why this exists

Production deploys reference specific tags (e.g. `v6.0.1-2026-05-13`).
GHCR's default garbage-collection policy *can* delete untagged
manifests, and any future change to GitHub's org-plan retention defaults
could silently delete tagged manifests too. If that happens,
`kubectl rollout undo` will fail to pull the previous image and we
will be unable to revert a bad deploy.

This policy pins production tags to a 2-year retention window so the
rollback path is always available.

## Tag classification

| Tag shape                  | Example                  | Pinned? | Retention      |
|---                         |---                       |---      |---             |
| `v<MAJOR>.<MINOR>.<PATCH>` | `v6.0.1`, `v6.0.1-2026-05-13` | yes | 730 days (2 yr) |
| any other tag              | `local`, `dev`, `pr-123` | no      | GHCR default   |

The production regex is `^v\d+\.\d+\.\d+` and is enforced in
`.github/workflows/pin-prod-images.yml`.

## How pinning works

1. Operator runs `gh workflow run pin-prod-images.yml -f package=<name>
   -f tag=<vX.Y.Z-...>` (or the same UI in the Actions tab).
2. The workflow validates the tag against the prod regex, looks up the
   GHCR package version ID, and records the pin in `pinned_images.log`
   at the repo root.
3. The audit log is committed back to the repo by the workflow.
4. Quarterly audit (below) cross-references this log against GHCR's
   actual versions to detect drift.

GHCR does not (as of 2026-05) expose a per-version retention field via
the REST API. The pin is enforced by two negative invariants:

- We do not run any workflow that deletes versions whose tags match the
  prod regex.
- The audit log is checked into source control, so any unintended
  deletion is detectable in PR review.

If/when GHCR ships a per-version retention API, the workflow's
"Mark version as pinned" step becomes a real `PATCH` call.

## Kubernetes manifest annotations

Every prod-running Deployment carries:

```yaml
metadata:
  labels:
    instanode.dev/image-pinned: "true"
  annotations:
    instanode.dev/image-pin-retention-days: "730"
```

This is informational only — it does *not* enforce retention. It exists
so audits are one command:

```bash
kubectl get deploy -A -l instanode.dev/image-pinned=true \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

## Disaster recovery

**Scenario:** a pinned image was GC'd anyway (GitHub policy change,
account suspension, accident).

**Recovery steps:**

1. Pull the running pod and inspect `/healthz` to recover the git SHA:
   ```bash
   kubectl -n instant exec deploy/instant-api -- wget -qO- http://localhost:8080/healthz | jq .commit_id
   ```
   (See `instant.dev/common/buildinfo` — `GIT_SHA` is baked at build
   time via `-ldflags` and printed by every service's healthz.)

2. Check out that SHA locally and rebuild with the *same* version tag:
   ```bash
   git checkout <sha>
   GIT_SHA=$(git rev-parse --short HEAD)
   docker build -f api/Dockerfile -t ghcr.io/instanode-dev/instant-api:v6.0.1-2026-05-13 \
     --build-arg GIT_SHA=$GIT_SHA \
     --build-arg BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
     --build-arg VERSION=v6.0.1-2026-05-13 .
   docker push ghcr.io/instanode-dev/instant-api:v6.0.1-2026-05-13
   ```

3. Re-run `pin-prod-images.yml` to re-pin the rebuilt manifest.

4. If `kubectl rollout undo` had already failed, re-trigger it now that
   the image is back.

**Why this works:** the binary stamps `GIT_SHA` into
`instant.dev/common/buildinfo` at build time, and rebuilds from the same
SHA produce a functionally-equivalent image even if the manifest digest
differs (Go reproducibility is best-effort, but for rollback what
matters is behavior, not byte-for-byte sameness).

## Quarterly audit

Run on the first Monday of each quarter:

```bash
# 1. Diff pinned_images.log against GHCR ground truth.
for pkg in instant-api instant-provisioner instant-worker; do
  echo "=== $pkg ==="
  gh api "/orgs/InstaNode-dev/packages/container/$pkg/versions?per_page=100" \
    --jq '.[] | .metadata.container.tags[]' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u > /tmp/ghcr-$pkg.txt
  awk -v pkg=$pkg '$2==pkg {print $3}' pinned_images.log | sort -u > /tmp/log-$pkg.txt
  echo "in log but missing from GHCR:"
  comm -23 /tmp/log-$pkg.txt /tmp/ghcr-$pkg.txt
  echo "in GHCR but never pinned (action: run pin-prod-images.yml):"
  comm -13 /tmp/log-$pkg.txt /tmp/ghcr-$pkg.txt
done
```

Open an issue for any drift. "in log but missing from GHCR" is the
disaster-recovery trigger above; "in GHCR but never pinned" means a
prod tag shipped without going through the workflow — back-fill it.

## Bonus: SBOM

The same workflow generates an SPDX SBOM via `syft` and attaches it to
the GHCR image via `cosign attach sbom`. This is best-effort
(`continue-on-error: true`) so a transient SBOM failure does not block
the pin. The SBOM unlocks:

- Vulnerability scanning via `grype ghcr.io/instanode-dev/instant-api:vX.Y.Z`
- SOC2 supply-chain evidence ("what was in this image on what date")

## Operator dependencies (one-time)

1. Create a GitHub PAT with scopes `read:packages, write:packages`
   against the `InstaNode-dev` org. Store as repo secret
   `GHCR_RETENTION_TOKEN`.

2. Back-fill: run `pin-prod-images.yml` once for each currently-running
   production tag. List them with:
   ```bash
   kubectl get deploy -A -l instanode.dev/image-pinned=true \
     -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}'
   ```
