# Data-Tier Apply Runbook — `instant-data` stateful hardening

> Companion to `k8s/APPLY-CHECKLIST.md` (which covers the api/worker/
> provisioner **Deployment** manifests). This runbook covers the **stateful
> data-tier** manifests in `k8s/data/` — the ones that hold real customer data
> and therefore must be applied deliberately, in order, in a maintenance
> window. **This repo has no auto-apply (CLAUDE.md rule 15).**
>
> **CRITICAL: never `kubectl apply -f k8s/app.yaml`** (stale vs prod — strips
> `imagePullSecrets`, resets images). The files below are individually
> applyable; apply them one at a time and read each `--dry-run=server` diff.

This runbook is the operator apply checklist for four changes that are
**committed but NOT yet applied to prod** (infra has no auto-apply):

| Tag | File | What it does | Customer-visible risk if mis-applied |
|---|---|---|---|
| **S1** | `k8s/data/postgres-customers-lockdown.yaml` + the patched `postgres-customers.yaml` | pg_hba that REJECTS the admin/superuser roles (`instanode_admin`, `instant_cust`) from the public path; preserves `usr_*` customer roles | LOW — admin-only reject; customers unaffected. Detailed runbook: `POSTGRES-CUSTOMERS-LOCKDOWN-RUNBOOK.md` |
| **S2** | `k8s/data/networkpolicy.yaml` | ingress NetworkPolicy: only provisioner/migrator/worker (+ nats-proxy for 4222) may reach the data pods | **HIGH — can break ALL customers** if the pg-proxy allow-rule is missing. See §S2 below. |
| **R6** | `k8s/data/nats.yaml` | JetStream `emptyDir{}` → PVC (`nats-jetstream-pvc`, 5Gi) so queue data survives restarts | LOW — but the migration step (§R6) drains existing in-memory JetStream state. |
| **R7** | `k8s/data/stateful-priority.yaml` + resource requests in `{postgres-customers,mongodb,redis-provision}.yaml` | PriorityClass `instant-data-critical` + one PDB per stateful pod + right-sized requests (BestEffort → Burstable) | LOW — eviction-ordering + drain-gating only; no data-path change. |

---

## Pre-flight (every apply below)

```bash
# 1. Confirm context — NEVER run against the wrong cluster.
kubectl config current-context
# Expected for prod: do-nyc3-instant-prod

# 2. Snapshot current data-tier state for rollback reference.
kubectl get pods,pvc,netpol,pdb,priorityclass -n instant-data -o wide
kubectl get priorityclass instant-data-critical 2>/dev/null || echo "no priorityclass yet"

# 3. Server-side dry-run EACH file and read the diff line by line.
kubectl apply --dry-run=server -f <file>
```

Apply in a **maintenance window**. The recommended order is **R7 → R6 → S1 →
S2** — least-risky and reversible first, the customer-breaking NetworkPolicy
LAST so it is the freshest thing in your head if customers report errors.

---

## R7 — PriorityClass + PDBs + resource requests (apply FIRST)

Pure eviction-protection; no data-path change. Two parts.

**Part A — the PriorityClass + PDBs:**

```bash
kubectl apply --dry-run=server -f k8s/data/stateful-priority.yaml   # read diff
kubectl apply              -f k8s/data/stateful-priority.yaml

# Verify
kubectl get priorityclass instant-data-critical
kubectl get pdb -n instant-data
# Expect 4 PDBs (postgres-customers / mongodb / redis-provision / nats),
# each ALLOWED DISRUPTIONS reading 0 (single replica, minAvailable 1 → the one
# pod is "not disruptable" by voluntary eviction, which is the point).
```

**Part B — the resource requests + the priorityClassName patch.** The requests
ship INSIDE each workload manifest (`mongodb.yaml`, `redis-provision.yaml`,
`postgres-customers.yaml`). Re-applying those manifests rolls the pod (Recreate
strategy → brief downtime per workload — do this in the window). Because the
PriorityClass is deliberately NOT inlined in the Deployments (so the priority
rollout is one auditable step), patch `priorityClassName` in the same roll:

```bash
# postgres-customers carries the S1 pg_hba mount already — apply it as part of
# S1 below (§S1) to avoid two rolls. For mongodb + redis-provision, roll now:
for w in mongodb redis-provision; do
  kubectl apply --dry-run=server -f k8s/data/$w.yaml   # read diff: only resources{} added
  kubectl apply              -f k8s/data/$w.yaml
  kubectl patch deploy/$w -n instant-data --type=merge \
    -p '{"spec":{"template":{"spec":{"priorityClassName":"instant-data-critical"}}}}'
  kubectl rollout status deploy/$w -n instant-data --timeout=180s
done

# Verify QoS flipped from BestEffort → Burstable and priority is set:
kubectl get pod -n instant-data -l app=mongodb \
  -o jsonpath='{.items[0].status.qosClass}{" "}{.items[0].spec.priorityClassName}{"\n"}'
# Expect: Burstable instant-data-critical
```

> nats already declared requests; just patch its `priorityClassName` (do it in
> the R6 roll below so nats only restarts once).

**Rollback R7:** `kubectl delete -f k8s/data/stateful-priority.yaml` removes the
PDBs + PriorityClass (pods keep running; priorityClassName on a pod referencing
a deleted class is harmless until the next reschedule — re-patch to remove).

---

## R6 — NATS JetStream emptyDir → PVC

`k8s/data/nats.yaml` now declares `nats-jetstream-pvc` (5Gi, default
StorageClass = `do-block-storage` on DOKS) and mounts it at `/data/jetstream`.

> **Data note:** pre-cutover JetStream state lived in `emptyDir{}` and is
> **already non-durable** (every prior restart wiped it). Switching to the PVC
> does NOT migrate old in-memory state — there is nothing durable to migrate.
> Existing `legacy_open` queue resources reconnect + re-establish streams on
> reconnect (same as any nats restart today). Schedule during low queue
> traffic; clients reconnect automatically.

```bash
kubectl apply --dry-run=server -f k8s/data/nats.yaml   # read diff: PVC added, volume swapped

# The Deployment uses strategy.type: Recreate (RWO volume — required). Applying
# rolls the pod: old pod terminates, PVC binds, new pod starts on /data/jetstream.
kubectl apply -f k8s/data/nats.yaml

# Patch the PriorityClass in the SAME context so nats restarts once (R7 part B):
kubectl patch deploy/nats -n instant-data --type=merge \
  -p '{"spec":{"template":{"spec":{"priorityClassName":"instant-data-critical"}}}}'

kubectl rollout status deploy/nats -n instant-data --timeout=180s

# Verify the PVC bound and JetStream is on it:
kubectl get pvc nats-jetstream-pvc -n instant-data        # STATUS Bound
kubectl exec -n instant-data deploy/nats -- ls -la /data/jetstream
kubectl get pod -n instant-data -l app=nats \
  -o jsonpath='{.items[0].status.qosClass}{" "}{.items[0].spec.priorityClassName}{"\n"}'
# Expect a jetstream dir on the mounted PVC + Burstable instant-data-critical.

# Durability proof (the whole point): publish to a stream, delete the pod,
# confirm the message survives the restart.
# kubectl exec ... nats pub test.durability hello ; kubectl delete pod -l app=nats ;
# (after Ready) nats stream info / consumer next — message must still be there.
```

**Rollback R6:** revert the `nats.yaml` change and re-apply (volume goes back to
`emptyDir{}`). The PVC can be left bound (it costs a few cents) or deleted with
`kubectl delete pvc nats-jetstream-pvc -n instant-data` once nats is off it.

---

## S1 — postgres-customers admin lockdown

Full procedure (root-cause, role analysis, proxy-IP SNAT caveat, the live
pg_hba stopgap) is in **`POSTGRES-CUSTOMERS-LOCKDOWN-RUNBOOK.md`** — follow THAT
for S1; this is the short pointer + the verification gate.

Apply order: the `postgres-customers-hba` ConfigMap (in
`postgres-customers-lockdown.yaml`) FIRST, then the patched
`postgres-customers.yaml` (which mounts the hba file via subPath + sets
`hba_file=/etc/postgresql/pg_hba.conf` and now also carries the R7
resource requests). Roll postgres-customers ONCE for both:

```bash
kubectl apply -f k8s/data/postgres-customers-lockdown.yaml   # ConfigMap (+ any docs)
kubectl apply -f k8s/data/postgres-customers.yaml            # mounts hba + R7 requests
kubectl patch deploy/postgres-customers -n instant-data --type=merge \
  -p '{"spec":{"template":{"spec":{"priorityClassName":"instant-data-critical"}}}}'
kubectl rollout status deploy/postgres-customers -n instant-data --timeout=300s
```

> ⚠️ Read `POSTGRES-CUSTOMERS-LOCKDOWN-RUNBOOK.md §3a` BEFORE applying — the
> pg-proxy SNATs customer traffic to a pod IP, so the lockdown rejects the
> admin role BY ROLE NAME (`instanode_admin` AND `instant_cust`), not by source
> IP. If the runbook's proxy-pod-IP reject lines are stale, fix them first.

### S1 verification gate (the load-bearing check)

After the roll, the **external admin path MUST FAIL** while in-cluster admin and
customer paths keep working:

```bash
# (a) EXTERNAL admin connect MUST be REJECTED by pg_hba (NOT a password prompt
#     that proceeds). SAFE: connection-rejection probe only — no SQL/DDL.
PGCONNECT_TIMEOUT=5 psql \
  "host=pg.instanode.dev port=5432 user=instant_cust dbname=instant_customers sslmode=require" \
  -c '\q' 2>&1 | head
# EXPECT: 'no pg_hba.conf entry for host ... rejected' (or FATAL 28000 from the
#         proxy). FAILURE TO REJECT = lockdown not in effect — STOP, investigate.

# Repeat for the OTHER admin role (the confirmed truehomie role):
PGCONNECT_TIMEOUT=5 psql \
  "host=pg.instanode.dev port=5432 user=instanode_admin dbname=instant_customers sslmode=require" \
  -c '\q' 2>&1 | head
# EXPECT: rejected.

# (b) In-cluster admin still works (provisioner path is intact):
kubectl exec -n instant-data deploy/postgres-customers -- \
  psql -U instant_cust -d instant_customers -tAc 'select 1;'   # expect: 1

# (c) A real customer usr_<token> still connects through the public path
#     (regression check — the lockdown must NOT catch customer roles).
#     Use a known test-tenant DSN from the dashboard / a /db/new claim.
```

**Rollback S1:** see `POSTGRES-CUSTOMERS-LOCKDOWN-RUNBOOK.md §Rollback` (revert
the manifest, the pod falls back to the stock catch-all pg_hba; the live file
backup is at `$PGDATA/pg_hba.conf.bak.2026-06-03`).

---

## S2 — data-tier ingress NetworkPolicy (apply LAST — highest risk)

`k8s/data/networkpolicy.yaml` adds a default-deny ingress policy per data pod,
allowing ONLY provisioner / migrator / worker (+ nats-proxy for 4222/8222).

### ⚠️ The pg-proxy allow-rule — this is the customer-breaking trap

The `postgres-customers-ingress` policy as committed **does NOT list
`instant-pg-proxy`** — the allow-rule for it is **DORMANT** (commented out at
`networkpolicy.yaml` lines ~88–103). If the public customer connect path is
`pg.instanode.dev → ingress-nginx tcp-services → instant-pg-proxy
(instant ns) → postgres-customers`, then applying this policy AS-IS
**default-denies the proxy and BREAKS EVERY CUSTOMER POSTGRES CONNECTION.**

`POSTGRES-CUSTOMERS-LOCKDOWN-RUNBOOK.md §L4` records that as of 2026-06-06 the
NetworkPolicy is **NOT applied in prod** and that applying it as-is would
default-deny + break the proxy path. **Do not apply S2 until you have:**

1. **Confirmed the live proxy deployment's namespace + pod labels:**
   ```bash
   kubectl get pods -A -l app=instant-pg-proxy -o wide
   # (the proxy manifest lives in the separate InstaNode-dev/instant-pg-proxy
   #  repo, NOT here — read the real ns + labels off the live cluster.)
   ```
2. **Uncommented + edited the dormant pg-proxy block** in
   `networkpolicy.yaml` (lines ~88–103) to match those real ns/labels.
3. **Confirmed Cilium (the CNI) actually enforces NetworkPolicy** in this
   cluster (`kubectl get ds -n kube-system | grep cilium`).

Only then:

```bash
kubectl apply --dry-run=server -f k8s/data/networkpolicy.yaml   # read diff
kubectl apply              -f k8s/data/networkpolicy.yaml
```

### S2 verification gate (must run IMMEDIATELY after apply)

```bash
# (a) Legit in-cluster caller (provisioner) still reaches postgres-customers:
kubectl exec -n instant-infra deploy/instant-provisioner -- \
  sh -c 'nc -z -w5 postgres-customers.instant-data.svc.cluster.local 5432 && echo OK'
# Expect: OK

# (b) THE CUSTOMER PATH still works — connect a real customer usr_<token>
#     through pg.instanode.dev (same DSN as S1 check (c)). If this now FAILS
#     where it worked pre-apply, the pg-proxy allow-rule is missing/wrong:
#       kubectl delete -f k8s/data/networkpolicy.yaml   # IMMEDIATE rollback
#     then fix the dormant pg-proxy block and re-apply.

# (c) The 4 NetworkPolicies are present:
kubectl get networkpolicy -n instant-data
# Expect: postgres-customers-ingress, redis-provision-ingress, mongodb-ingress,
#         nats-ingress.
```

**Rollback S2 (do this fast if customers report connection errors):**

```bash
kubectl delete -f k8s/data/networkpolicy.yaml
# Removing the policies returns the pods to allow-all ingress (the pre-apply
# state). No data loss; instant effect.
```

---

## Apply-order summary

| # | Tag | Command | Verify | Reversible |
|---|---|---|---|---|
| 1 | R7-A | `kubectl apply -f k8s/data/stateful-priority.yaml` | `kubectl get pdb,priorityclass -n instant-data` | `kubectl delete -f …` |
| 2 | R7-B | apply `mongodb.yaml`,`redis-provision.yaml` + patch `priorityClassName` | QoS = Burstable | re-apply prior manifest |
| 3 | R6 | `kubectl apply -f k8s/data/nats.yaml` (+ priorityClassName patch) | PVC Bound + durability publish/restart test | revert manifest |
| 4 | S1 | apply lockdown ConfigMap + `postgres-customers.yaml` (+ patch) | **external admin psql REJECTED** | per lockdown runbook |
| 5 | S2 | **edit dormant pg-proxy rule FIRST**, then apply `networkpolicy.yaml` | provisioner reaches pg AND customer path works | `kubectl delete -f …` |

After every step, sanity-check the platform hot path:

```bash
curl -sS https://api.instanode.dev/healthz | jq .
curl -sS https://api.instanode.dev/readyz  | jq .   # data-tier deep readiness
```

---

## Related

- `k8s/APPLY-CHECKLIST.md` — the api/worker/provisioner Deployment apply rules.
- `POSTGRES-CUSTOMERS-LOCKDOWN-RUNBOOK.md` — the full S1 procedure + root cause.
- `NATS-AUTH-RUNBOOK.md` — NATS operator-mode key generation (separate from R6).
- `k8s/data/networkpolicy.yaml` — the S2 policy with the dormant pg-proxy block.
- CLAUDE.md rule 15 — why this repo has no auto-apply.
