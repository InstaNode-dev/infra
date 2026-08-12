# L4 customer data-plane proxies

`pg.instanode.dev:5432`, `redis.instanode.dev:6379` and `mongo.instanode.dev:27017` are the
hostnames stamped into every customer connection string. They terminate at ingress-nginx's
TCP passthrough, which forwards to the three proxies defined here.

## Why these manifests did not exist until 2026-08-12

They ran on DigitalOcean as **hand-applied cluster objects that were never committed** — the
canonical statement is `k8s/ingress/README.md`, which notes the three proxies live in a
separate `InstaNode-dev/instant-pg-proxy` family of repos rather than here. Nothing in `infra/`
could recreate them, and the greenfield AKS cluster consequently came up with every issued
connection string pointing at a hostname with nothing listening behind it.

The images survived, privately, under the operator's personal GHCR namespace:

| Proxy | Image |
|---|---|
| pg-proxy | `ghcr.io/mastermanas805/instant-pg-proxy:v0.2.0` |
| redis-proxy | `ghcr.io/mastermanas805/instant-redis-proxy:v0.1.0` |
| mongo-proxy | `ghcr.io/mastermanas805/instant-mongo-proxy:v0.4.2-no-awaitable` |
| nats-proxy | `ghcr.io/mastermanas805/instant-nats-proxy:v0.1.3` (manifest in `k8s/nats-proxy/` pins v0.1.0 — prod ran ahead) |

They are **private packages**, so a `ghcr-pull` imagePullSecret is required in namespace
`instant`. Create it with a PAT carrying `read:packages` **only** — never a token with `repo`
scope, which would put full repository write access inside a cluster Secret:

```bash
kubectl create secret docker-registry ghcr-pull -n instant \
  --docker-server=ghcr.io --docker-username=mastermanas805 --docker-password="$READ_PACKAGES_PAT"
```

## Routing model — read before changing the fallback

Each proxy demuxes by database/key name using routes published to Redis under a
`*_route:` prefix, and falls back to a fixed backend when Redis has no route.

That fallback is **the entire routing story on the current cluster.** The route registry is
populated only by the *dedicated* (`k8s`) provisioning backends, and this cluster deliberately
runs the *shared* backends — every customer database lives on the one `postgres-customers`
pod, every cache on `redis-provision`, every collection on `mongodb`. So the fallback is not a
degraded path here; it is the path. The Redis URL is still wired so that turning dedicated
backends back on works without touching these manifests.

## pg-proxy carries a security control, not just routing

`PG_PROXY_DENIED_ROLES` rejects `instanode_admin`, `instant_cust` and `postgres` at the proxy.
Those are superuser roles on the shared customer Postgres, and the proxy is the one place that
can refuse them before authentication: connections arrive SNAT'd to a pod IP, so `pg_hba` sees
an in-cluster source address and cannot distinguish a customer from an operator. Removing this
env var silently re-opens the path implicated in the 2026-06-03 `truehomie-db` DROP incident.

## Apply order

1. `ghcr-pull` Secret (above) — without it, all three land in `ImagePullBackOff`.
2. `kubectl apply -f k8s/proxies/`
3. Add the TCP mappings and load-balancer ports — see `k8s/ingress/values-ingress-nginx-aks.yaml`,
   where 5432/6379/27017 are present but commented out. The Helm values must be re-applied for
   the Service to expose the ports; editing the `ingress-nginx-tcp` ConfigMap alone is not enough.
