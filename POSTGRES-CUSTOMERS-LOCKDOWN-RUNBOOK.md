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

### CONFIRMED LIVE during the 2026-06-06 apply session (supersedes H1–H3 below)

| # | Finding | How confirmed |
|---|---|---|
| L1 | **TWO superuser roles exist on the prod customer pod:** `instanode_admin` (rolsuper=t — the role api/worker connect with via `CUSTOMER_DATABASE_URL`) AND `instant_cust` (rolsuper=t + createdb + createrole — the `POSTGRES_USER` the provisioner connects with via `POSTGRES_CUSTOMERS_URL`). The PR's pg_hba listed only `instant_cust`. **Manifest FIXED to reject BOTH** before apply — else the catch-all customer rule re-opens the vector for `instanode_admin` (the confirmed truehomie role). | `psql -tAc "select rolname,rolsuper from pg_roles where rolsuper"`; `kubectl get secret instant-secrets -o jsonpath CUSTOMER_DATABASE_URL` → `instanode_admin`; provisioner deploy env `POSTGRES_CUSTOMERS_URL` → `instant_cust` |
| L2 | **A LIVE pg_hba stopgap was already on the pod** (from the 2026-06-03 incident): `host all instanode_admin <pod-ip>/32 reject` for the THEN proxy pod IPs (`10.109.3.201`, `10.109.0.101`), plus catch-all `host all all all scram`. One rejected IP (`10.109.3.201`) is now **STALE** — the proxy rescheduled to `10.109.4.113` — so the stopgap is partially broken. This ConfigMap's **role-keyed** reject is the churn-proof replacement. Live file backed up at `$PGDATA/pg_hba.conf.bak.2026-06-03`. | `kubectl exec … cat $PGDATA/pg_hba.conf`; `kubectl get pods -l app=instant-pg-proxy -o wide` |
| L3 | **pg-proxy is a custom TCP proxy that SNATs.** `instant-pg-proxy:v0.1.0` (in `instant` ns) routes by Redis prefix `pg_route:` with `PG_PROXY_FALLBACK_BACKEND=postgres-customers.instant-data.svc:5432`. Being a TCP proxy it terminates inbound + re-originates, so customer traffic arrives at postgres-customers as the **proxy pod IP (10.x)**. This confirms the role-based (not source-IP) reject is the correct boundary, and confirms the **fallback** would forward an admin connection straight through (the live vector). | `kubectl get deploy/instant-pg-proxy -o jsonpath env` |
| L4 | **The `postgres-customers-ingress` NetworkPolicy is NOT applied in prod** (`kubectl get netpol -n instant-data` → "No resources found"). Cilium IS the CNI (policies would enforce if applied). So the network layer provides **zero** protection today — the pg_hba role-reject is the **sole** boundary. The NetworkPolicy was therefore **NOT applied** in this session (applying it as-is would default-deny + break the proxy path, which is not in its allow-list). | `kubectl get networkpolicy -n instant-data`; `kubectl get ds -n kube-system \| grep cilium` |
| L5 | **No committed public-admin automation.** `grep -rI pg.instanode.dev` across all repos finds it only as the customer-facing `POSTGRES_PUBLIC_HOST` (the `usr_*` path); nothing pairs it with an admin DSN. `tcp-services` cm currently maps `5432 → instant/instant-pg-proxy` (its `last-applied` annotation shows it was ORIGINALLY `5432 → instant-data/postgres-customers`, i.e. a former direct-to-pod route — historical corroboration of the vector). | `grep`; `kubectl get cm -n ingress-nginx tcp-services -o yaml` |

> **Net:** H1's *vector* is now fully corroborated end-to-end (public DNS → LB →
> ingress tcp-services → SNATting pg-proxy with a fallback → catch-all pg_hba),
> the proxy behaviour (H2) and NetPol non-enforcement (H3) are RESOLVED above. We
> still did NOT attempt auth as the admin role (no destructive pentest); the
> apply-time external test (§5b) uses a connection-rejection probe only.

### ORIGINAL HYPOTHESES (pre-apply; superseded by L1–L5 above)

| # | Open item | Why it could not be confirmed at PR time |
|---|---|---|
| H1 | That an external actor **actually authenticated** as the admin role over the public path. | We deliberately did **not** attempt auth (out-of-scope noisy/destructive pentest). C1–C3 prove the path is *open*, not that it was *used*. |
| H2 | The `instant-pg-proxy`'s own role-gate / `pg_hba` behaviour and whether it already blocks the admin role. | The proxy config lives in the **separate repo `InstaNode-dev/instant-pg-proxy`**. **RESOLVED L3:** it SNATs + has an open fallback (no role gate in v0.1.0). |
| H3 | Whether the existing `postgres-customers-ingress` NetworkPolicy is enforced in prod. | infra has no auto-apply; requires a live `kubectl get netpol -n instant-data` (operator). **RESOLVED L4:** NOT applied. |

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

### 3a. ⚠️ The pg-proxy SNAT problem — proxy-pod-IP reject is REQUIRED (and churns)

**LIVE-VERIFIED 2026-06-06, and it changes the design:** `instant-pg-proxy` is a
normal in-cluster pod (not hostNetwork) that terminates the inbound TCP and
re-originates to `postgres-customers`. So EVERY public connection — including an
external `psql -U instanode_admin` — arrives SNAT'd to a **proxy pod IP inside
10.109.x (i.e. inside 10.0.0.0/8)**. A plain `instanode_admin 10.0.0.0/8 allow`
would therefore MATCH a SNAT'd external admin and NOT close the vector. Baseline
probe before apply confirmed the live vector is OPEN: `psql -U instanode_admin`
over `pg.instanode.dev` returns `password authentication failed` (it REACHED
scram). The proxy v0.1.0 has no role gate and an open fallback.

**Consequence for the ConfigMap:** the admin reject MUST list the CURRENT proxy
pod IPs and be ordered BEFORE the `10.0.0.0/8` allow (first-match wins). Get them:

```bash
kubectl get pods -n instant -l app=instant-pg-proxy -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}'
# Put these into the `host all instanode_admin <ip>/32 reject` (and instant_cust)
# lines at the TOP of the admin block in postgres-customers-lockdown.yaml.
```

**⚠️ CHURN (historical — now mitigated by the durable role-gate, see below):**
these IPs change when the proxy reschedules — that is exactly how the 2026-06-03
hand-stopgap silently broke (it listed `10.109.3.201`, now dead). After ANY proxy
reschedule, re-run the command above, update the two reject lines, re-apply the
ConfigMap, and `SELECT pg_reload_conf()`.

**✅ DURABLE FIX SHIPPED + DEPLOYED (2026-06-06) — the churn dependency is closed.**
The pg-proxy's own privileged-role deny (`PG_PROXY_DENIED_ROLES`) is LIVE: repo
`InstaNode-dev/instant-pg-proxy` (created 2026-06-06; it did not exist before),
PR #1 (merge `5a86c93`), image `ghcr.io/mastermanas805/instant-pg-proxy:v0.2.0`,
env `PG_PROXY_DENIED_ROLES=instanode_admin,instant_cust,postgres,doadmin`. The
proxy now rejects admin roles at the StartupMessage with a FATAL `28000`
ErrorResponse BEFORE resolving/dialing — **independent of pod IPs / pg_hba.**
Live-verified: after the rollout the proxy runs on NEW IPs (`10.109.6.132`,
`10.109.4.98`) that the pg_hba reject lines do NOT name, yet external admin is
still rejected (at the proxy, not pg_hba). The pg_hba proxy-IP reject lines are
therefore now **redundant belt-and-suspenders** — left in place (harmless), no
longer the sole boundary, no longer require churn-refresh on reschedule.
**✅ RESIDUAL CLOSED (2026-06-06).** Both halves of the remaining follow-up are done:
1. **Manifest committed (durable).** `PG_PROXY_DENIED_ROLES` no longer lives only on
   a live `kubectl patch`. The proxy Deployment + Service are now committed to
   `InstaNode-dev/instant-pg-proxy` under `k8s/` (`deployment.yaml`, `service.yaml`,
   `README.md`) as the source of truth. The manifest was captured faithfully from the
   live spec and is a **verified no-op** — `kubectl diff -f k8s/deployment.yaml -n instant`
   returned empty (exit 0), confirming it matches the running proxy (image `v0.2.0` +
   the role-gate env) and re-applying it changes nothing. A future `kubectl delete` +
   `kubectl apply -f k8s/` therefore restores the gate instead of silently dropping it.
   Re-apply is safe at any time; no apply is needed today (already matches live).
2. **Alert shipped (operator-apply).** Two log-based NR alerts watch the gate:
   - `infra/newrelic/alerts/pg-proxy-role-gate-disabled.json` (P0/CRITICAL) — fires when
     a proxy pod logs `pgproxy.role_gate` with `"denied_role_count":0` (gate disabled,
     e.g. a re-create that dropped the env).
   - `infra/newrelic/alerts/pg-proxy-down.json` (P1/CRITICAL) — fires when the proxy
     emits zero logs for 10m (proxy down / public path broken).
   Both query the proxy's stdout JSON in NR (`k8s_namespace_name='instant' AND
   k8s_label_app='instant-pg-proxy'`), shipped via the `newrelic-logging` Fluent Bit
   DaemonSet (verified running, all nodes). Dashboard: `admin-defense.json` →
   "pg-proxy public-path gate" page (4 tiles). Catalog row in
   `infra/observability/METRICS-CATALOG.md`.
   **Why log-based (interim):** the proxy is a thin TCP proxy with slog-to-stdout only —
   it exposes **no `/metrics` endpoint**, so a Prometheus-metric rule is not possible
   today. The log signal (`pgproxy.role_gate denied_role_count`) is the lowest-effort
   reliable alarm and needs zero code change. **Proper durable upgrade (follow-up):**
   add a `pgproxy_role_gate_denied_roles` gauge + an HTTP `/metrics` listener to the
   proxy, scrape it, alert on `gauge == 0`, AND add a worker synthetic-reject prober leg
   (open a raw StartupMessage to `pg.instanode.dev` as `instanode_admin`, assert FATAL
   `28000`). Until then the log alerts are the alarm.

- If the proxy-pod-IP reject lines in the ConfigMap do NOT match the live proxy
  IPs at apply time → FIX them first, else the lockdown is a no-op for the live
  public path.

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
- ~~It does **not** touch the `instant-pg-proxy` repo~~ — **superseded 2026-06-06:**
  the durable fix (the proxy's own `PG_PROXY_DENIED_ROLES` role-gate) IS now shipped
  + deployed (repo `InstaNode-dev/instant-pg-proxy` PR #1, image v0.2.0). This
  runbook's pg_hba lockdown is now the belt-and-suspenders layer behind that gate.
  See §3a + the §9 Drill Log row 2.
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

---

## 9. Drill Log

| Date | Operator | Action | Result |
|---|---|---|---|
| 2026-06-06 | Claude (operator-authorized apply, "no customers, low blast radius") | **APPLIED to do-nyc3-instant-prod.** Merged PR #61 (squash, merge commit `78cb6677`) after fixing the manifest for two live findings (see below). Applied ConfigMap `postgres-customers-hba`; patched `deploy/postgres-customers` to mount it + `-c hba_file=/etc/postgresql/pg_hba.conf -c password_encryption=scram-sha-256`; changed strategy `RollingUpdate→Recreate` (RWO PVC Multi-Attach). Did NOT apply `networkpolicy.yaml` (verified NOT enforced in prod; applying as-is would default-deny the proxy path). | **SUCCESS.** External admin REJECTED at pg_hba (both `instanode_admin` + `instant_cust`, error names the SNAT'd proxy pod IP) — baseline beforehand reached scram (vector was OPEN). In-cluster admin preserved: provisioner `instant_cust` CREATE/DROP smoke OK, api/worker `instanode_admin` connect + `pg_database_size` OK, customer `usr_*` path still reaches scram. No rollback. |
| 2026-06-06 | Claude (operator-authorized, "no customers, low blast radius") | **DURABLE FIX SHIPPED + DEPLOYED — the churn-proof pg-proxy role-gate.** Created the `InstaNode-dev/instant-pg-proxy` repo (did not exist before — the proxy source was a loose, un-versioned local dir; live image was `ghcr.io/mastermanas805/instant-pg-proxy:v0.1.0` applied by hand, no committed manifest). Merged PR #1 (squash, merge commit `5a86c93`): the proxy parses the StartupMessage `user` and, if in `PG_PROXY_DENIED_ROLES`, returns a FATAL `28000` ErrorResponse (`role is not permitted over the public endpoint`) BEFORE resolving/dialing — default empty = inert. Built+pushed `ghcr.io/mastermanas805/instant-pg-proxy:v0.2.0`; `kubectl patch deploy/instant-pg-proxy -n instant` → image v0.2.0 + `PG_PROXY_DENIED_ROLES=instanode_admin,instant_cust,postgres,doadmin`. | **SUCCESS — durable closure verified, pod-IP-independent.** Rollout landed new pods at `10.109.6.132`/`10.109.4.98` (NOT the `10.109.4.113`/`10.109.0.101` the pg_hba reject lines name — those lines now point at DEAD pods, yet admin is STILL rejected, proving independence). External `instanode_admin`/`instant_cust`/`postgres` over `pg.instanode.dev` → **proxy 28000** (`role is not permitted over the public endpoint`), NOT a pg_hba reject naming a pod IP. Proxy logged `user_denied_public` for all three. Customer `usr_*` → FORWARDED (reached postgres scram → `password authentication failed`, not 28000). In-cluster admin via ClusterIP svc UNAFFECTED: `instant_cust` CREATE+DROP OK (`INCLUSTER_PROVISION_PATH_OK`), `pg_database_size` quota read OK. Provisioner DSN confirmed → `postgres-customers.instant-data.svc.cluster.local:5432` (svc, NOT the public proxy). The pg_hba proxy-IP reject lines are now redundant belt-and-suspenders (left in place, harmless). |
| 2026-06-06 | Claude (operator-authorized, "no customers, low blast radius") | **RESIDUAL CLOSED — role-gate persisted to a committed manifest + alerted.** The `PG_PROXY_DENIED_ROLES` env previously lived ONLY on the live `kubectl patch` (a manual Deployment re-create would have silently dropped it → reopened the admin vector). (1) Captured the LIVE spec faithfully (`kubectl get deploy/svc instant-pg-proxy -n instant -o yaml`), stripped live-only noise, committed `k8s/deployment.yaml` + `k8s/service.yaml` + `k8s/README.md` to `InstaNode-dev/instant-pg-proxy` (default branch master) as the source of truth (PR, squash auto-merge). (2) Added two log-based NR alerts (operator-apply) — `pg-proxy-role-gate-disabled.json` (P0; fires on `pgproxy.role_gate denied_role_count==0`) + `pg-proxy-down.json` (P1; fires on 10m proxy log silence) — plus an admin-defense dashboard page + METRICS-CATALOG row (infra PR, squash auto-merge). The proxy exposes no `/metrics`, so the log signal is the lowest-effort reliable alarm; a `pgproxy_role_gate_denied_roles` gauge + synthetic-reject prober leg are the documented durable upgrade. | **SUCCESS — manifest is a verified no-op vs live; live behavior unchanged.** `kubectl diff -f k8s/deployment.yaml -n instant` → empty output, exit 0 (tooling sanity-checked: a deliberate `replicas: 2→3` edit DID surface drift, so the empty diff is genuine). `kubectl diff -f k8s/service.yaml` → also empty/exit 0. Live state at capture: image `v0.2.0`, `PG_PROXY_DENIED_ROLES=instanode_admin,instant_cust,postgres,doadmin`, pods Running 2/2, `pgproxy.role_gate denied_role_count:4` in logs, and live `pgproxy.user_denied_public` events observed for `instanode_admin`/`instant_cust`/`postgres` (gate actively rejecting). `newrelic-logging` Fluent Bit DaemonSet confirmed running on all nodes (proxy stdout reaches NR `Log`). NO `kubectl apply` performed (not needed — manifest already matches live); operator may apply anytime safely. The infra alerts are operator-apply. |

**Manifest fixes made before apply (live pre-apply verification):**
1. **`instanode_admin` was missing.** Prod has TWO superusers — `instanode_admin` (api/worker `CUSTOMER_DATABASE_URL`, the CONFIRMED truehomie vector) and `instant_cust` (provisioner `POSTGRES_CUSTOMERS_URL`). The original PR rejected only `instant_cust`; `instanode_admin` would have matched the catch-all customer allow → vector still open. Both now rejected.
2. **pg-proxy SNAT defeats source-CIDR.** instant-pg-proxy (in-cluster, no hostNetwork) re-originates TCP, so external admin arrives SNAT'd to a proxy pod IP inside `10.0.0.0/8` — a plain `10.0.0.0/8 allow` matches it. Added proxy-pod-IP `reject` lines (`10.109.4.113`, `10.109.0.101`) ordered BEFORE the in-cluster allow. **Verified in the reject error message** (`rejects connection for host "10.109.0.101"`). ⚠️ Churn dependency, see §3a.

**Operator follow-ups created by this apply:**
- ~~**Ship the durable pg-proxy role-gate**~~ ✅ **DONE 2026-06-06.** `PG_PROXY_DENIED_ROLES` shipped (repo `InstaNode-dev/instant-pg-proxy` created + PR #1, merge `5a86c93`), image `v0.2.0` built+pushed, deployed to `deploy/instant-pg-proxy` with `PG_PROXY_DENIED_ROLES=instanode_admin,instant_cust,postgres,doadmin`. Live-verified the closure is now pod-IP-independent (see §3a + Drill Log row 2). The closure no longer depends on the churning proxy-pod-IP reject lines.
- ~~**On any `instant-pg-proxy` reschedule:** refresh the proxy-IP reject lines~~ — **no longer required for the security boundary** (the role-gate is now the durable boundary). The pg_hba IP reject lines are redundant belt-and-suspenders; leave them. ~~Still recommended: add a proxy-pod-restart alert for visibility, and persist `PG_PROXY_DENIED_ROLES` into a committed proxy Deployment manifest~~ — **✅ DONE 2026-06-06** (see the "RESIDUAL CLOSED" block in §3a and Drill Log row 3): the proxy Deployment+Service are committed to `InstaNode-dev/instant-pg-proxy` `k8s/` (verified no-op vs live via `kubectl diff`), and two log-based NR alerts (`pg-proxy-role-gate-disabled.json` + `pg-proxy-down.json`) + the admin-defense "pg-proxy public-path gate" dashboard page watch the gate. The proxy has no `/metrics`, so a `pgproxy_role_gate_denied_roles` gauge + synthetic-reject prober leg are the proper durable upgrade (follow-up).
- **`k8s/data/postgres-customers.yaml` updated** to carry the mount/args/Recreate-strategy so a future repo apply does not silently revert the lockdown (shipped in the same follow-up PR).
- The repo `apply.yml` workflow now includes `postgres-customers-lockdown.yaml` (safe — ConfigMap) but ALSO `networkpolicy.yaml`; running that workflow WOULD create the unenforced-today NetPol and default-deny the proxy path. Add it to the apply EXCLUDE list or add the pg-proxy ingress rule before anyone runs the workflow.
