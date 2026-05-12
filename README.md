# instant-infra

Kubernetes manifests and docker-compose configuration for the instanode.dev platform.

## Local development

```bash
docker compose up -d
```

## Kubernetes (Rancher Desktop / k3s)

```bash
# Copy and fill in secrets
cp k8s/secrets.yaml k8s/secrets.local.yaml
# edit k8s/secrets.local.yaml with real values

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secrets.local.yaml
kubectl apply -f k8s/
```

## Secrets

Never commit `secrets.local.yaml`. The checked-in `k8s/secrets.yaml` contains only `CHANGE_ME` placeholders.

**DO NOT naive-apply `secrets.yaml` against a live cluster** — see
[`k8s/README.md`](k8s/README.md) section "Secret operations — DO NOT naive-apply"
and use `k8s/scripts/safe-secret-apply.sh`.
