# instant-infra

Kubernetes manifests and docker-compose configuration for the instant.dev platform.

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
