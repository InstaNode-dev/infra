# k8s manifests

Kubernetes manifests for the instanode.dev platform. Applied to a Rancher Desktop /
k3s cluster locally, and to the production cluster via the same files.

## Secret operations — DO NOT naive-apply

The `secrets.yaml` and `infra-secrets.yaml` files in this repo are TEMPLATES.
They ship `CHANGE_ME` for every production secret. They are NOT the source
of truth — the cluster is.

A naive `kubectl apply -f secrets.yaml` will overwrite live AES_KEY, JWT_SECRET,
RAZORPAY_*, DATABASE_URL, PROVISIONER_SECRET, MIGRATOR_SECRET, OBJECT_STORE_*,
etc. with the literal string `CHANGE_ME`. Pods will crashloop on the bad
AES_KEY because it is no longer a 64-char hex string. This actually happened
on 2026-05-12 during an observability rollout (the "B3 incident") and required
manual recovery by extracting real values from still-running pod environments.

### Never do this

```bash
kubectl apply -f k8s/secrets.yaml         # CLOBBERS prod secrets with CHANGE_ME
kubectl apply -f k8s/infra-secrets.yaml   # CLOBBERS prod infra secrets with CHANGE_ME
kubectl apply -f k8s/                     # Same thing, hidden inside a directory apply
```

### Adding a NEW secret key (one-time, when the template adds a field)

```bash
# Extract the new key only and patch it
kubectl patch secret instant-secrets -n instant --type=merge -p '{
  "stringData":{"NEW_KEY_NAME":"<real-value>"}
}'
```

For the infra namespace:

```bash
kubectl patch secret instant-infra-secrets -n instant-infra --type=merge -p '{
  "stringData":{"NEW_KEY_NAME":"<real-value>"}
}'
```

### Rotating an EXISTING secret value

Same `kubectl patch` pattern, replacing the existing value. Or use a
sealed-secrets operator if installed.

### Safe-apply script

If you must apply a secrets YAML file, use the safety wrapper. It refuses
to apply any YAML containing `CHANGE_ME` placeholders:

```bash
./k8s/scripts/safe-secret-apply.sh k8s/secrets.local.yaml
```

The script is documented at [`scripts/safe-secret-apply.sh`](scripts/safe-secret-apply.sh).

The intended workflow for first-time setup on a new cluster:

```bash
cp k8s/secrets.yaml k8s/secrets.local.yaml
# edit k8s/secrets.local.yaml with real values
./k8s/scripts/safe-secret-apply.sh k8s/secrets.local.yaml
```

`secrets.local.yaml` is gitignored and never committed.

### Recovery (if a naive apply just clobbered prod)

1. Get the list of `CHANGE_ME`-clobbered keys from a still-running pod
   that has cached env:

   ```bash
   kubectl exec deployment/<service> -n <namespace> -- env | grep -vE "CHANGE_ME$"
   ```

   (Use a pod that has NOT yet been restarted since the bad apply. Pods load
   secrets into env at startup, so a still-running pod still holds the real
   values until it restarts.)

2. Patch each key back to its real value with `kubectl patch secret ...`.

3. Restart any pods that have already restarted and picked up the bad values
   (they will be in CrashLoopBackOff if the secret is required for startup).

### Future improvement

This repo does not yet use a pre-commit framework. A pre-commit hook that
refuses to *add new* `CHANGE_ME` lines to a secrets YAML would catch the
case where a contributor pastes real secrets into the template by mistake.
See `scripts/safe-secret-apply.sh` for the current runtime guardrail.
