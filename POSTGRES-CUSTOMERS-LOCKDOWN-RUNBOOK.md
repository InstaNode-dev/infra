# postgres-customers Admin Lockdown Runbook

> **Status: DORMANT. Operator-applied in a maintenance window. This repo has no
> auto-apply (rule 15). Nothing here runs automatically.**
>
> **HIGH BLAST RADIUS — touches the shared customer-Postgres data tier. Requires
> USER/OPERATOR review and a maintenance window before apply.**
>
> Closes the OPEN root cause of the **truehomie-db DROP incident (2026-06-03)**:
> a direct, public-internet admin connection to `postgres-customers` that could
> `DROP DATABASE` with no `audit_log` row. Memory:
> `project_truehomie_db_drop_incident_2026_06_03`. Audit:
> `docs/ci/DATA-INTEGRITY-DROP-PATH-AUDIT.md` (§truehomie root-cause hypotheses,
> H1 = confirmed vector).

---

## 1. What was confirmed vs hypothesis (verify-don't-assert)

### CONFIRMED — via config + SAFE checks (2026-06-06)

| # | Finding | How confirmed |
|---|---|---|
| C1 | `pg.instanode.dev` → `152.42.154.144` — the SAME IP as `api`/`redis`/`mongo.instanode.dev` (the shared DO LoadBalancer fronting ingress-nginx). pg is **publicly DNS-routed**. | `dig +short pg.instanode.dev` (and the three siblings) |
| C2 | `pg.instanode.dev:5432` **answers a TCP handshake from the public internet.** | `nc -z -w5 pg.instanode.dev 5432` → "succeeded" (**TCP only — no auth, no SQL, no DDL attempted**) |
| C3 | The `postgres-customers` pod runs the **stock `pgvector/pgvector:pg16` image** with **NO** custom `pg_hba.conf` / `postgresql.conf` / `POSTGRES_HOST_AUTH_METHOD` and **no config volume mount** → the image default `host all all all scram-sha-256` (a **catch-all**) is in effect. The admin/superuser role (`instant_cust`, the `POSTGRES_USER`) can authenticate from any source that reaches the listener. | `k8s/data/postgres-customers.yaml` (only the data PVC is mounted; no `command`/`args`/`POSTGRES_HOST_AUTH_METHOD`); no `pg_hba.conf`/`postgresql.conf` anywhere in the infra repo |
| C4 | The `postgres-customers` **Service is ClusterIP** (no `type:` field). The public exposure is via the external `instant-pg-proxy` + ingress-nginx `tcp-services`, **NOT** this Service. | `k8s/data/postgres-customers.yaml` Service spec |
| C5 | A `postgres-customers-ingress` NetworkPolicy already exists allowing ingress on 5432 only from provisioner/migrator/worker (all `instant-infra`). It does **not** list pg-proxy. **Its prod-apply state is unverified** (infra has no auto-apply). | `k8s/data/networkpolicy.yaml` |

### STILL HYPOTHESIS — NOT confirmable from this repo (do not assert)

| # | Open item | Why it can't be confirmed here |
|---|---|---|
| H1 | That an external actor **actually authenticated** as the admin role over the public path. | We deliberately did **not** attempt auth (out-of-scope noisy/destructive pentest). C1–C3 prove the path is *open*, not that it was *used*. |
| H2 | The `instant-pg-proxy`'s own role-gate / `pg_hba` behaviour and whether it already blocks the admin role. | The proxy config lives in the **separate repo `InstaNode-dev/instant-pg-proxy`** (per the audit doc), not here. |
| H3 | Whether the existing `postgres-customers-ingress` NetworkPolicy is enforced in prod. | infra has no auto-apply; requires a live `kubectl get netpol -n instant-data` (operator). |

> **Net:** the exposure (public-reachable customer-Postgres listener + a
> catch-all default pg_hba that lets the admin role auth from anywhere) is
> **CONFIRMED at the config + reachability level**. Whether it was the actual
> truehomie dropper, and the proxy's own gate, remain hypothesis. The hardening
> agent's #1 hypothesis is therefore **corroborated, not refuted**.

---

## 2. Legitimate consumers of postgres-customers (must NOT break)

| Consumer | How it connects | Role | Preserved by this lockdown? |
|---|---|---|---|
| **instant-provisioner** (`instant-infra`) | `POSTGRES_CUSTOMERS_URL` admin DSN, in-cluster to `postgres-customers.instant-data.svc:5432` | **admin** (`instant_cust`) — CREATE/DROP `db_<token>` + `usr_<token>` | **Yes** — pg_hba allows `instant_cust` from `10.0.0.0/8` (pod CIDR). NetPol already allows provisioner. |
| **instant-migrator** (`instant-infra`) | in-cluster, resource migrations (CopyData/Verify) | admin or per-tenant | **Yes** — same pod-CIDR admin allow + NetPol already allows migrator. |
| **instant-worker** (`instant-infra`) | in-cluster, read-only `pg_database_size` (quota tick) | admin (read) | **Yes** — pod-CIDR admin allow + NetPol already allows worker. |
| **Customers** | public `pg.instanode.dev:5432` → pg-proxy → `db_<token>` | per-tenant **`usr_<token>`** (non-superuser) | **Yes** — pg_hba `host all all 0.0.0.0/0 scram-sha-256` LAST rule still allows customer roles from anywhere. The admin reject does NOT catch them (role name != `instant_cust`/`postgres`). |
| **backup CronJob** (`postgres-customers-backup`) | in-cluster `pg_dumpall` (BACKUP-RESTORE-RUNBOOK) | admin | **Yes** — runs in-cluster (pod CIDR) as the admin role. *Operator: verify its pod lands in 10.0.0.0/8 — it does, all DOKS pods are in pod CIDR.* |
| **restore-drill sidecar** | throwaway namespace, never touches the live pod | n/a | Unaffected. |

**The one thing this CLOSES:** a direct `psql -h pg.instanode.dev -U instant_cust`
(or `-U postgres`) from **outside** the cluster. That is the truehomie vector.

> **Unverifiable-consumer caution:** if any **ad-hoc operator/CI workflow**
> currently connects to the admin role over the **public** `pg.instanode.dev`
> (e.g. a migration run from a laptop or a GitHub Action), the lockdown will
> **break it by design** — that path IS the vulnerability. Before apply, the
> operator MUST confirm no legitimate automation depends on public admin access
> (search CI secrets / workflows for `pg.instanode.dev` + an admin DSN). If one
> exists, migrate it to an in-cluster runner / `kubectl exec` first.

---

## 3. Pre-apply verification (do this FIRST, in the window)

```bash
kubectl config current-context        # MUST be do-nyc3-instant-prod

# (a) Is the existing ingress NetworkPolicy enforced? (H3)
kubectl get netpol -n instant-data postgres-customers-ingress -o yaml | sed -n '1,60p'

# (b) Where is pg-proxy, and does customer traffic SNAT through it? (H2)
#     The proxy manifest is in the SEPARATE instant-pg-proxy repo; find it live:
kubectl get pods -A | grep -i pg-proxy
kubectl get svc,cm -A | grep -iE 'tcp-services|pg-proxy'
#     Inspect ingress-nginx tcp-services to see what 5432 maps to:
kubectl get cm -n ingress-nginx tcp-services -o yaml 2>/dev/null

# (c) Does a real customer connection currently work end-to-end? (baseline to
#     compare AFTER lockdown — use a KNOWN test tenant's usr_/db_, NOT admin)
#     (operator runs from a real customer connection string they own)

# (d) Confirm the admin role name actually is `instant_cust` (POSTGRES_USER) on
#     the live pod (don't trust the manifest blindly):
kubectl exec -n instant-data deploy/postgres-customers -- \
  psql -U instant_cust -d instant_customers -tAc "select rolname,rolsuper from pg_roles where rolsuper;"
#     Expect the superuser to be `instant_cust` (and possibly `postgres`).
#     If the admin role differs, EDIT the pg_hba ConfigMap to match BEFORE apply.

# (e) Confirm no legitimate automation uses PUBLIC admin access:
#     (search your CI secrets/workflows + local shell history for the DSN)
#     grep your repos for: pg.instanode.dev .* instant_cust  (or :@pg.instanode.dev)
```

**Decision gate:**
- If (d) shows a different admin role → fix the ConfigMap, re-run pre-apply.
- If (e) finds a public-admin automation → migrate it in-cluster FIRST.
- If (b) shows pg-proxy SNATs and (a) shows the NetPol enforced and customers
  currently work → the NetPol must already allow the proxy somehow; do NOT touch
  the NetPol, rely on the pg_hba role-reject alone. **If customers do NOT
  currently work, that is a pre-existing issue — do not conflate it with this
  lockdown.**

---

## 4. Apply (online pg_hba reload first; pod patch is the durable step)

The pg_hba change is **online-reloadable** — no customer downtime for the
config itself. The pod patch (to mount the ConfigMap + start with the custom
`hba_file`) is a **pod restart** (single-replica → brief connect blip; provisioner
retries; customers reconnect).

```bash
kubectl config current-context        # do-nyc3-instant-prod — re-confirm

# 1. Apply the ConfigMap (inert until mounted — safe to apply anytime).
kubectl apply -f k8s/data/postgres-customers-lockdown.yaml

# 2. Patch the Deployment to mount the ConfigMap and start postgres with the
#    custom hba_file. (Single, reviewable strategic patch — read the diff first.)
kubectl patch deploy/postgres-customers -n instant-data --type=strategic -p '
spec:
  template:
    spec:
      containers:
        - name: postgres
          args: ["-c", "hba_file=/etc/postgresql/pg_hba.conf", "-c", "password_encryption=scram-sha-256"]
          volumeMounts:
            - name: hba
              mountPath: /etc/postgresql/pg_hba.conf
              subPath: pg_hba.conf
              readOnly: true
      volumes:
        - name: hba
          configMap:
            name: postgres-customers-hba
            items:
              - key: pg_hba.conf
                path: pg_hba.conf
'
#    NOTE: the container name on the live pod is `postgres` (per the manifest).
#    Confirm with: kubectl get deploy/postgres-customers -n instant-data \
#      -o jsonpath='{.spec.template.spec.containers[0].name}'

# 3. Wait for the new pod to be Ready.
kubectl rollout status deploy/postgres-customers -n instant-data --timeout=180s

# (Alternative to a restart, if you want ZERO downtime and the file is already
#  mounted on a prior apply: edit pg_hba on the pod's mounted path is read-only,
#  so the reload path is to update the ConfigMap and `pg_ctl reload`:)
#   kubectl exec -n instant-data deploy/postgres-customers -- \
#     psql -U instant_cust -d instant_customers -c "SELECT pg_reload_conf();"
```

---

## 5. Verify AFTER apply

### 5a. Legitimate access STILL works (do these FIRST)

```bash
# Provisioner admin path (in-cluster) — must still authenticate:
kubectl exec -n instant-data deploy/postgres-customers -- \
  psql -U instant_cust -d instant_customers -tAc "select 1;"        # expect: 1

# A provisioning smoke test through the real API (creates + lists a db):
curl -sS -X POST https://api.instanode.dev/db/new | jq '.connection_string!=null'  # expect true
#   then connect to the returned connection string as the customer (usr_ role)
#   from OUTSIDE the cluster and run `select 1;` — expect SUCCESS (customer path
#   preserved).

# Backup CronJob smoke (or wait for the nightly): trigger a manual run and
# confirm it still dumps (BACKUP-RESTORE-RUNBOOK §verify).
kubectl create job -n instant-data --from=cronjob/postgres-customers-backup pg-lockdown-verify
kubectl logs -n instant-data job/pg-lockdown-verify --follow   # expect a clean dumpall
```

### 5b. External ADMIN access is CLOSED (the whole point)

```bash
# From a machine OUTSIDE the cluster, attempt the ADMIN role over the public host.
# EXPECT: rejected by pg_hba ("no pg_hba.conf entry ... rejected"), NOT a password
# prompt that proceeds. This is a SAFE connection-rejection test — it does NOT
# require valid credentials and runs NO SQL.
PGCONNECT_TIMEOUT=5 psql "host=pg.instanode.dev port=5432 user=instant_cust dbname=instant_customers sslmode=require" -c '\q' 2>&1 | head
#   PASS = an explicit pg_hba REJECT / "no pg_hba.conf entry for host ... user
#          \"instant_cust\" ... rejected" (FATAL).
#   FAIL = a password prompt / "password authentication failed" (means the hba
#          rule did NOT reject — admin is still reachable; ROLL BACK + investigate).
# (The TCP handshake will still succeed — that is expected; the boundary is the
#  pg_hba role reject, not the port. The customer usr_* path is unaffected.)
```

> The TCP port stays open (customers need it). The boundary is the **role-level
> reject** at pg_hba. If you want the port itself closed to the public, that is a
> separate, larger change in the `instant-pg-proxy` repo + ingress-nginx
> tcp-services (do not attempt as part of this lockdown).

---

## 6. Rollback

```bash
# Revert the pod patch (drops the custom hba_file + mount → back to image default):
kubectl patch deploy/postgres-customers -n instant-data --type=json -p '[
  {"op":"remove","path":"/spec/template/spec/containers/0/args"},
  {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts/0"},
  {"op":"remove","path":"/spec/template/spec/volumes/0"}
]'
kubectl rollout status deploy/postgres-customers -n instant-data --timeout=180s

# Optionally delete the ConfigMap (inert either way):
kubectl delete cm -n instant-data postgres-customers-hba --ignore-not-found
```

Rollback restores the (vulnerable) catch-all default. Only roll back if a
**legitimate** consumer breaks — and capture which one, because that maps to a
consumer the analysis missed.

---

## 7. What this does NOT do (scope honesty)

- It does **not** close the public TCP port on 5432 (customers connect there).
  The admin boundary is the pg_hba **role reject**, not the port.
- It does **not** touch the `instant-pg-proxy` repo (the proxy's own role-gate /
  pg_hba is the durable fix tracked separately, per memory + the audit doc).
- It does **not** prove the truehomie dropper used this path (H1 remains
  hypothesis) — it removes the *capability*, which is the right action regardless.
- It does **not** by itself add an audit trail for in-cluster admin DROPs — that
  is the provisioner `guardedDrop` chokepoint (already shipped, audit doc §Layer 1)
  + the DDL-logging trap set on the cluster (memory).

---

## 8. Defense-in-depth context (already shipped elsewhere)

This lockdown is the **infra** half of the truehomie fix. The **application** half
is already shipped (audit doc):
- provisioner `guardedDrop` chokepoint + DDL-audit log + `instant_provisioner_drop_total` (PR #50)
- CI guard test: no raw DROP outside the chokepoint (PR #50)
- NR alert + dashboard tile + catalog row for the drop metric (infra PR #60, merged)

Together: this runbook removes the *unaudited external admin DROP capability*;
the chokepoint ensures every *sanctioned* drop is recorded; the CI guard ensures a
*new* unaudited drop call site cannot be merged.
