# Spot node pool — scheduling contract

> Added 2026-08-09 as part of the DigitalOcean → Azure AKS port.

The AKS cluster has two node pools:

| Pool | SKU | Autoscale | Taint | Runs |
|---|---|---|---|---|
| `system` | `Standard_B2as_v2` (2 vCPU / 8 GiB) | 1 → 3 | none | everything in `instant`, `instant-infra`, `instant-data`, `ingress-nginx`, `cert-manager`, `newrelic`, `kube-system` |
| `spot` | `Standard_B2ls_v2` **Spot** | **0** → 2 | `kubernetes.azure.com/scalesetpriority=spot:NoSchedule` (applied automatically by AKS) | Kaniko build Jobs + customer deploy pods only |

The pool is **scale-to-zero**: it costs nothing at rest and the cluster autoscaler
brings a node up when a pod that tolerates the taint goes Pending.

## The two halves of the contract

**Half 1 — nothing platform-side may tolerate the Spot taint.** A Spot node can be
evicted by Azure with 30 seconds' notice. Any platform or data-tier pod that lands
there is a surprise outage. Audited 2026-08-09 across all of `infra/k8s/**`:

| Workload | Tolerations | Verdict |
|---|---|---|
| `instant-api`, `instant-worker`, `instant-provisioner`, `instant-migrator`, `instant-website`, `instant-nats-proxy` | none | ✅ cannot land on Spot |
| `postgres-customers`, `mongodb`, `redis-provision`, `nats` | none | ✅ cannot land on Spot |
| `newrelic-prometheus-agent` | none | ✅ |
| `image-puller` (DaemonSet) | **was `operator: Exists` — fixed** | ✅ now pinned off Spot via `kubernetes.azure.com/scalesetpriority DoesNotExist` |
| `github-runner` | none | ✅ |

`kubectl get pods -A -o json | jq -r '.items[] | select(.spec.tolerations // [] |
any(.operator == "Exists" and (.key // "") == "")) | "\(.metadata.namespace)/\(.metadata.name)"'`
re-runs that audit on a live cluster. A blanket `operator: Exists` with no key is
the pattern to look for — it tolerates the Spot taint by accident.

**Half 2 — build + deploy pods must carry the toleration AND the nodeSelector.**
A toleration alone only makes a pod *eligible* for the tainted pool; without a
`nodeSelector` the scheduler still prefers the (cheaper-to-schedule, already-running)
system node. Both are required:

```yaml
nodeSelector:
  kubernetes.azure.com/scalesetpriority: spot
tolerations:
  - key: kubernetes.azure.com/scalesetpriority
    operator: Equal
    value: spot
    effect: NoSchedule
```

`kubernetes.azure.com/scalesetpriority=spot` is applied by AKS itself to every Spot
node (label **and** taint) purely from `priority = "Spot"` on the node pool — no
custom taint is needed from Terraform. `spot-scheduling-policy.yaml` in this
directory additionally tolerates an optional custom `instanode.dev/spot=true:NoSchedule`
taint so the policy keeps working if one is ever added; tolerating an absent taint
is a no-op.

## Who sets Half 2 — and why it is not in a manifest

The build Jobs and customer Deployments are **created at runtime by the api**, in
per-deploy namespaces (`instant-deploy-<appID>`, `instant-stack-<slug>`) that do not
exist until the request arrives. They are not in this repo and cannot be patched here.

Verified 2026-08-09 in `api/internal/providers/compute/k8s/`:

```
rg -n 'Tolerations|NodeSelector|Affinity|PriorityClassName' \
   client.go stack.go build_context.go custom_domain.go
→ no matches
```

The api sets **no** scheduling constraints on either the Kaniko Job or the runtime
Deployment. So as shipped today the Spot pool stays at zero nodes forever and every
build runs on the system node.

There are two ways to close that. Pick one:

**(a) `spot-scheduling-policy.yaml` in this directory — a Kyverno mutating policy.**
No api change. Kyverno injects the nodeSelector + toleration into any pod created in
an `instant-deploy-*` / `instant-stack-*` / `instant-apps` namespace. Requires Kyverno
(already a prerequisite for `k8s/preview/02-policies.yaml`). `failurePolicy: Ignore`
so a Kyverno outage degrades to "builds run on the system node", never to "builds
fail". This is the interim, and it is reversible with a single `kubectl delete`.

**(b) The api-repo change — see the follow-up ticket in the AKS port report.**
`K8sProvider` grows `BUILD_NODE_SELECTOR` / `BUILD_NODE_TOLERATION` config and stamps
both onto the Kaniko Job PodSpec and the customer Deployment PodSpec. Strictly better
than (a): no admission-webhook dependency in the deploy hot path, visible in the
Job spec, and testable in the api's own suite. Do this, then delete (a).

Do **not** run both expecting them to compose — Kyverno's mutate is additive and
would append a duplicate toleration. Harmless, but noisy. Delete the policy when the
api change ships.
