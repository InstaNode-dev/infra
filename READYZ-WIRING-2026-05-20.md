# /readyz wiring — k8s manifest diff (NOT auto-applied)

## Context

Today's `/healthz` is a shallow liveness probe — DB ping + commit_id only. The
Brevo silent-rejection bug from 2026-05-20 (and analogous upstream blips) is
invisible to it. Three repo PRs land `/readyz` with component-by-component
checks (platform_db, customer_db, provisioner_grpc, brevo, razorpay, redis,
do_spaces, river) per service.

This file is the k8s manifest diff. **Do not auto-apply.** Apply manually
after the new images deploy + the existing `/healthz` is verified untouched.

## Why manual

`/healthz` stays wired to `livenessProbe`. The risk is that a misconfigured
`/readyz` returns 503 every probe → kubelet pulls every pod → outage. Verify
on one pod first (`kubectl port-forward` + `curl /readyz`) before flipping
the readinessProbe.

## Diff 1 — `infra/k8s/app.yaml` (api)

```diff
           readinessProbe:
             httpGet:
-              path: /healthz
+              path: /readyz
               port: 8080
-            initialDelaySeconds: 5
-            periodSeconds: 10
-            failureThreshold: 3
+            initialDelaySeconds: 10
+            periodSeconds: 15
+            timeoutSeconds: 5
+            failureThreshold: 3
           livenessProbe:
             httpGet:
               path: /livez          # process-only check; see startupProbe note
               port: 8080
             initialDelaySeconds: 15
             periodSeconds: 30
             failureThreshold: 6
```

**What changes:** readinessProbe now points at `/readyz` (deep check),
`livenessProbe` stays at `/livez` (shallow). `periodSeconds` bumps from 10s
to 15s so the per-check cache (10s TTL) saves an upstream call per period.
`timeoutSeconds: 5` is added explicitly so a slow Brevo probe can't stall
the probe (the runner's internal `OverallTimeout: 3s` is well within this).

**Why livenessProbe stays at `/livez`:** a Brevo outage must NOT restart the
api pod. `/livez` is the pure process-up signal — wired correctly today.

## Diff 2 — `infra/k8s/worker/deployment.yaml`

```diff
           readinessProbe:
             httpGet:
-              path: /healthz
+              path: /readyz
               port: 8091
-            initialDelaySeconds: 10
-            periodSeconds: 10
-            failureThreshold: 3
+            initialDelaySeconds: 10
+            periodSeconds: 15
+            timeoutSeconds: 5
+            failureThreshold: 3
           livenessProbe:
             httpGet:
               path: /healthz        # worker serves only /healthz (no /livez)
               port: 8091
             initialDelaySeconds: 15
             periodSeconds: 30
             failureThreshold: 6
```

**Note:** the worker has no Service endpoint to be pulled from, so a 503
on `/readyz` is purely an observability signal today (readiness fires the
NR alert and updates the Prometheus gauge; nothing routes around the
pod). If a future PR adds a worker Service for in-cluster lookups, the
readiness gate is already wired.

## Diff 3 — `infra/k8s/provisioner/deployment.yaml`

```diff
           readinessProbe:
             httpGet:
-              path: /healthz
+              path: /readyz
               port: 8092
-            initialDelaySeconds: 5
-            periodSeconds: 10
-            failureThreshold: 3
+            initialDelaySeconds: 10
+            periodSeconds: 15
+            timeoutSeconds: 5
+            failureThreshold: 3
           livenessProbe:
             httpGet:
               path: /healthz        # provisioner serves only /healthz (no /livez)
               port: 8092
             initialDelaySeconds: 15
             periodSeconds: 30
             failureThreshold: 6
```

**Provisioner extra:** the provisioner's gRPC server now registers the
standard `grpc.health.v1.Health` service so the api's `/readyz` check
`provisioner_grpc` works (it calls `Check(service="")`). No manifest
change is required for that — it's a code change inside the provisioner
binary.

## Rollout order (per CLAUDE.md rule 23 — verify-live each step)

1. **api** (largest blast radius). Build + push + rollout. Verify on
   one pod via `kubectl port-forward -n instant svc/instant-api 8080:8080`
   then `curl http://localhost:8080/readyz | jq .` Expect 200 + overall=ok
   (or degraded if Brevo/Razorpay configuration is in fact broken).
   Then apply Diff 1 and watch `kubectl get pods -n instant -w` for any
   Ready=False flapping.

2. **worker.** Same pattern with port-forward to `svc/instant-worker`
   (which doesn't exist as a Service today — `kubectl port-forward
   pod/<worker-pod> 8091:8091` instead). Apply Diff 2.

3. **provisioner.** `kubectl port-forward -n instant-infra
   svc/instant-provisioner 8092:8092` then `curl
   http://localhost:8092/readyz | jq .` Apply Diff 3.

## Verification commands

```bash
# 1) api — expect ok + 200, or degraded + 200 if Brevo etc. are configured wrong
curl https://api.instanode.dev/readyz | jq .

# 2) worker — in-cluster only
kubectl port-forward -n instant-infra pod/<worker-pod> 8091 &
curl http://localhost:8091/readyz | jq .

# 3) provisioner — in-cluster only
kubectl port-forward -n instant-infra svc/instant-provisioner 8092 &
curl http://localhost:8092/readyz | jq .

# 4) verify /healthz untouched on api (must still be the shallow shape)
curl https://api.instanode.dev/healthz | jq .
# expected: ok, service, commit_id, build_time, version, migration_*
```

## Rollback

```bash
# Revert one service:
kubectl set image -n instant deploy/instant-api app=ghcr.io/instanode-dev/api:<prev-sha>

# Or revert manifest:
git revert <commit>
kubectl apply -f infra/k8s/app.yaml
```

A pod that flips Ready=False on `/readyz` but Ready=True on the OLD
`/healthz` is benign — kubelet just stops sending it traffic. Revert
the readinessProbe path back to `/healthz` to restore the pre-change
behavior without re-deploying the binary.

## Why readiness, not liveness

`/readyz` checks upstream HTTP APIs (Brevo, Razorpay, DO Spaces). If any of
those is flapping, a livenessProbe on `/readyz` would SIGKILL every api pod
and a Brevo outage becomes an api outage. The readinessProbe just pulls the
pod from the Service endpoint list — no restart, just no new traffic.

The criticality matrix per service (which checks return 503 vs which
return 200+degraded) is hard-coded in handlers/readyz.go for each repo —
NOT env-tunable, because a misconfigured matrix is worse than no /readyz.

## Field names + wire shape

```json
{
  "overall": "ok" | "degraded" | "failed",
  "service": "instant-api",
  "commit_id": "<sha>",
  "checks": [
    {
      "name": "platform_db",
      "status": "ok" | "degraded" | "failed",
      "latency_ms": 3,
      "last_check_at": "2026-05-20T08:01:23Z",
      "last_error": ""
    },
    ...
  ]
}
```

Sorted by check name alphabetically so jq filters are stable across
probes.
