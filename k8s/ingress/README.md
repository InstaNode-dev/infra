# Ingress + TLS + L4 — AKS

> Added 2026-08-09 as part of the DigitalOcean → Azure AKS port.
>
> Everything in this directory previously existed **only as hand-applied objects
> on the DO cluster**. `k8s/app.yaml:435` pointed at a non-existent
> `infra/k8s/api-ingress.yaml`, and `CERT_ISSUER: letsencrypt-http01` named a
> ClusterIssuer that no manifest created. That gap is exactly why the live DO
> ingress was found serving `CN=Kubernetes Ingress Controller Fake Certificate`
> with no api behind it. The greenfield rebuild is the chance to make these
> repo-owned.

| File | What |
|---|---|
| `00-clusterissuer-letsencrypt-http01.yaml` | The `letsencrypt-http01` ClusterIssuer referenced by `app.yaml`, `configmap.yaml`, and every per-deploy Ingress the api creates |
| `10-api-ingress.yaml` | `api.instanode.dev` → `instant-api:8080`, TLS + the `proxy-body-size` that `/deploy/new` needs |
| `values-ingress-nginx-aks.yaml` | Helm values for the ingress-nginx install: static Azure IP, health-probe path, and the L4 (`tcp`) port map |

Not here, by design: the `*.deployment.instanode.dev` Ingresses are created **at
request time by the api** (one per deployed app, annotated with `CERT_ISSUER`) —
they are not static manifests.

## Install order

```bash
# 1. cert-manager (CRDs first — the ClusterIssuer below is a CRD instance)
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s

# 2. ingress-nginx, with the AKS values in this directory
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f k8s/ingress/values-ingress-nginx-aks.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

# 3. The issuer, then the Ingress (issuer first — the Ingress references it)
kubectl apply -f k8s/ingress/00-clusterissuer-letsencrypt-http01.yaml
kubectl apply -f k8s/ingress/10-api-ingress.yaml
```

## The DNS ordering trap

cert-manager cannot issue a certificate until the A record for the hostname
already resolves to the ingress LB — Let's Encrypt fetches
`http://api.instanode.dev/.well-known/acme-challenge/<token>` from the public
internet. So the order is:

1. Install ingress-nginx, read the assigned public IP
   (`kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`).
2. Point the Cloudflare A records at it, **DNS-only / grey cloud**.
3. *Then* apply the Ingress and watch `kubectl get certificate -n instant` go
   `Ready=True`.

Applying the Ingress first is not fatal — cert-manager retries with backoff —
but it burns Let's Encrypt failed-validation rate limit while it does.

**Keep every record grey-clouded.** An orange-clouded (proxied) record
terminates TLS at Cloudflare, which breaks the HTTP-01 round-trip *and* makes
the L4 listeners below unreachable, since Cloudflare's free proxy does not
forward arbitrary TCP.

## L4 (postgres / redis / mongo / nats)

`pg.instanode.dev:5432`, `redis.instanode.dev:6379`, `mongo.instanode.dev:27017`
and NATS `:4222` are raw TCP, not HTTP, so they cannot go through an Ingress
object. ingress-nginx forwards them via its `tcp-services` ConfigMap, which the
Helm chart generates from the `tcp:` block in
`values-ingress-nginx-aks.yaml` — that block also adds the ports to the
LoadBalancer Service, which a hand-written ConfigMap would not do. That is why
the port map lives in the values file rather than as a ConfigMap manifest here.

All four hostnames resolve to the **same** LB IP as `api.instanode.dev`; they
are distinguished by port, not by name (raw TCP carries no SNI for these
protocols).

⚠️ Three of the four backends (`instant-pg-proxy`, `instant-redis-proxy`,
`instant-mongo-proxy`) live in the **separate `InstaNode-dev/instant-pg-proxy`
family of repos** and are **not** in this repo. Only `instant-nats-proxy`
(`k8s/nats-proxy/deployment.yaml`) is here. The `tcp:` entries for the three
absent proxies are commented out in the values file — an entry pointing at a
nonexistent Service makes the controller log a config error on every reload.
Uncomment each as its proxy is deployed.

## Azure specifics baked into the values file

- **`service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path:
  /healthz`** — without it the Azure Standard LB health-probes the controller
  with a TCP connect only. That mostly works for HTTP but is unreliable once
  the `tcp:` ports are added, because the LB then probes an arbitrary listener.
  Pointing the probe at the controller's own `/healthz` is the documented AKS
  configuration.
- **`loadBalancerIP` + `service.beta.kubernetes.io/azure-load-balancer-resource-group`**
  — set these to pin the LB to the **static** Public IP that Terraform creates.
  Without a static IP, Azure assigns a dynamic one that changes on LB recreate,
  and every DNS record plus the Let's Encrypt validation breaks silently. This
  is a required Terraform output.
- **`externalTrafficPolicy: Local`** preserves the client source IP, which the
  api needs: the anonymous-abuse fingerprint is `SHA256(/24 subnet + ASN)`
  (CLAUDE.md rule 6). With the default `Cluster` policy every request appears to
  come from a node IP, collapsing every anonymous user into one fingerprint
  bucket and tripping the 5-provisions-per-day dedup cap for everyone at once.
