# Backup + Restore Runbook — instant-data (postgres-customers · mongodb · redis-provision)

Last drilled: **2026-05-20** (see "Drill Log" at bottom)
Drill cadence target: **monthly**, plus on every backup-cron YAML change.

This runbook is the operational source of truth for restoring the customer data plane
(`postgres-customers`, `mongodb`, `redis-provision`) from the nightly DigitalOcean Spaces
backups. **Pro tier marketing promises backups; this runbook is the evidence we can keep
that promise.** Until you have run `infra/scripts/restore-drill.sh` at least once, the
promise is unverified.

---

## 0. Pre-conditions

You will need:

| Thing | Why |
|---|---|
| `kubectl` pointed at `do-nyc3-instant-prod` | Backups live in the prod cluster's S3 bucket via the prod-side credentials. |
| Permission to create namespaces + pods in DOKS | The drill / restore spins up sidecars in a throwaway namespace. |
| Read access on the `instant-data/spaces-backup-creds` secret | Where the Spaces creds for `s3://instant-pg-backups` live. |
| (Real restore only) Permission to scale `postgres-customers` / `mongodb` Deployments to 0 | Cutover requires stopping writes against the live pod before pointing at restored data. |

Backup destination — same for all three services:

* **Bucket:** `s3://instant-pg-backups/` on **DigitalOcean Spaces, region `nyc3`**
* **Endpoint:** `https://nyc3.digitaloceanspaces.com`
* **Per-service prefix:** `postgres-customers/`, `mongodb/`, `redis-provision/`
* **Lifecycle policy:** `Expiration { Days: 30 }` — backups older than 30 days are
  auto-deleted by Spaces. **There is no off-bucket secondary copy** — if the bucket
  is lost, the durability promise is lost with it. See "Improvements backlog" below.

Schedule — all three services: **`0 3 * * *` UTC** (03:00 UTC daily).
`concurrencyPolicy=Forbid`, `startingDeadlineSeconds=600`, `successfulJobsHistoryLimit=3`,
`failedJobsHistoryLimit=3`, `ttlSecondsAfterFinished=86400`.

---

## 1. Backup CronJob inventory (snapshot 2026-05-20)

| CronJob | Source | Tool | Output object pattern | Latest size | Last success | Manifest |
|---|---|---|---|---|---|---|
| `postgres-customers-backup` | `postgres-customers.instant-data.svc.cluster.local:5432` (Deployment image `pgvector/pgvector:pg16`) | `pg_dumpall --clean --if-exists \| gzip -9` | `postgres-customers/instant-customers-backup-<UTC-ISO>.sql.gz` | ~148 KiB | 2026-05-20T03:02:49Z | [`k8s/backups/postgres-customers-backup.yaml`](k8s/backups/postgres-customers-backup.yaml) |
| `mongodb-backup` | `mongodb.instant-data.svc.cluster.local:27017` (Deployment image `mongo:7`) | `mongodump --archive --gzip --authenticationDatabase=admin` | `mongodb/mongodb-backup-<UTC-ISO>.archive.gz` | ~9.9 KiB | 2026-05-20T03:01:45Z | [`k8s/backups/mongodb-backup.yaml`](k8s/backups/mongodb-backup.yaml) |
| `redis-provision-backup` | `redis-provision.instant-data.svc.cluster.local:6379` | `redis-cli --rdb` (BGSAVE-equivalent over the wire) `\| gzip -9` | `redis-provision/redis-provision-backup-<UTC-ISO>.rdb.gz` | ~180 B (empty cluster) | 2026-05-20T03:00:44Z | [`k8s/backups/redis-provision-backup.yaml`](k8s/backups/redis-provision-backup.yaml) |

Live inventory:

```bash
kubectl get cronjobs -n instant-data
# NAME                        SCHEDULE    TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE
# mongodb-backup              0 3 * * *   Etc/UTC    False     0        ...
# postgres-customers-backup   0 3 * * *   Etc/UTC    False     0        ...
# redis-provision-backup      0 3 * * *   Etc/UTC    False     0        ...

# Per-service most-recent artifact:
SPACES_AK=$(kubectl get secret spaces-backup-creds -n instant-data \
  -o jsonpath='{.data.OBJECT_STORE_ACCESS_KEY}' | base64 -d)
SPACES_SK=$(kubectl get secret spaces-backup-creds -n instant-data \
  -o jsonpath='{.data.OBJECT_STORE_SECRET_KEY}' | base64 -d)
AWS_ACCESS_KEY_ID="$SPACES_AK" AWS_SECRET_ACCESS_KEY="$SPACES_SK" AWS_DEFAULT_REGION=nyc3 \
  aws s3 ls s3://instant-pg-backups/postgres-customers/ \
  --endpoint-url=https://nyc3.digitaloceanspaces.com | sort | tail -3
```

---

## 2. The drill (run this at least once a month)

```bash
bash infra/scripts/restore-drill.sh                          # both services
bash infra/scripts/restore-drill.sh --service=postgres-customers
bash infra/scripts/restore-drill.sh --service=mongodb
bash infra/scripts/restore-drill.sh --keep-ns                # for debugging
```

What it does:

1. Asserts `kubectl current-context == do-nyc3-instant-prod` (refuses to run otherwise).
2. Creates throwaway namespace `restore-drill-<unix-ts>`.
3. Copies the Spaces creds into that ns as a secret called `spaces-creds`.
4. Pulls the **latest** object under `postgres-customers/` and `mongodb/` (via a one-shot
   `alpine + apk add aws-cli` Job, log-scraped for the listing).
5. Streams the gzipped dump out of an awscli sidecar pod, into a local temp dir on the
   operator's machine.
6. Spins up a **fresh sidecar** in the drill ns (`pgvector/pgvector:pg16` for Postgres,
   `mongo:7.0` for Mongo) with empty storage.
7. Pipes the dump into `psql` / streams the archive into `mongorestore --drop` in the
   sidecar pod.
8. Runs **smoke queries** — see §6 — and FAILS LOUD if they return implausible counts.
9. Prints **RPO** (age of the artifact at restore time) and **RTO** (wall-clock seconds
   from sidecar-create to smoke-query-passed).
10. Deletes the throwaway namespace.

The drill never touches prod data — sidecar containers run with empty volumes and never
connect to the prod `postgres-customers` / `mongodb` services in `instant-data`.

---

## 3. Restore in anger — postgres-customers

> **NEVER restore over the running prod pod without first scaling it to zero.** The
> dump uses `pg_dumpall --clean --if-exists` which issues `DROP DATABASE` against every
> per-customer DB. If a customer is actively connected, that DROP will block; if you
> force it, you destroy in-flight writes.

### 3a. Decide: full-cluster restore, or single-database restore?

| Scenario | Use |
|---|---|
| Postgres pod data is lost / corrupt / volume gone | **Full-cluster restore** (§3b) |
| One specific customer's `db_<token>` got nuked, but the rest of the cluster is fine | **Single-DB restore** (§3c) |
| You're not sure yet — investigate first; restore plan can wait | **Read-only sidecar** via `bash infra/scripts/restore-drill.sh --keep-ns --service=postgres-customers` and inspect |

### 3b. Full-cluster restore

```bash
# 0. Pick the artifact. Default: most recent. For point-in-time, pick by timestamp.
SPACES_AK=$(kubectl get secret spaces-backup-creds -n instant-data \
  -o jsonpath='{.data.OBJECT_STORE_ACCESS_KEY}' | base64 -d)
SPACES_SK=$(kubectl get secret spaces-backup-creds -n instant-data \
  -o jsonpath='{.data.OBJECT_STORE_SECRET_KEY}' | base64 -d)
AWS_ACCESS_KEY_ID="$SPACES_AK" AWS_SECRET_ACCESS_KEY="$SPACES_SK" AWS_DEFAULT_REGION=nyc3 \
  aws s3 ls s3://instant-pg-backups/postgres-customers/ \
  --endpoint-url=https://nyc3.digitaloceanspaces.com | sort

# Pick one:
KEY="postgres-customers/instant-customers-backup-2026-05-20T030048Z.sql.gz"

# 1. ANNOUNCE the maintenance window. Restore is destructive — set status page.

# 2. Scale prod postgres-customers to 0 to stop new writes:
kubectl scale -n instant-data deploy/postgres-customers --replicas=0
kubectl wait -n instant-data --for=delete pod -l app=postgres-customers --timeout=120s

# 3. (CRITICAL) snapshot the existing PV before restore in case the restore goes wrong:
#    Easiest path: take a DigitalOcean volume snapshot of the PV via the DO console
#    or `doctl compute volume-action snapshot ...`. Record the snapshot ID here.

# 4. Bring postgres-customers back up empty. Easiest approach: blow away the PV
#    contents by recreating the StatefulSet/Deployment after deleting the PVC, OR —
#    SAFER — restore INTO a parallel pod and cut over by DNS/svc-selector swap.
#    For a documented straightforward path:

#    Scale back up (still pointed at the old PV; data is intact):
kubectl scale -n instant-data deploy/postgres-customers --replicas=1
kubectl wait -n instant-data --for=condition=Ready pod -l app=postgres-customers --timeout=120s

# 5. Download + stream the dump into the now-running pod:
AWS_ACCESS_KEY_ID="$SPACES_AK" AWS_SECRET_ACCESS_KEY="$SPACES_SK" AWS_DEFAULT_REGION=nyc3 \
  aws s3 cp s3://instant-pg-backups/${KEY} /tmp/restore.sql.gz \
  --endpoint-url=https://nyc3.digitaloceanspaces.com

POD=$(kubectl get pod -n instant-data -l app=postgres-customers -o name | head -1)
gunzip -c /tmp/restore.sql.gz | \
  kubectl exec -i -n instant-data "$POD" -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U instant_cust -d postgres -v ON_ERROR_STOP=0' \
    | tee /tmp/restore.log

# 6. Smoke-test (see §6) before scaling api back up. If smoke passes, you're done.
```

**Expected ERROR-line noise during step 5:** the dump uses `--clean --if-exists` against an
already-running cluster, so you will see a few thousand benign lines like:

* `ERROR:  cannot drop the currently open database` (psql can't drop `postgres` while connected)
* `ERROR:  current user cannot be dropped` (can't DROP ROLE `instant_cust` while it's the active user)
* `ERROR:  role "instant_cust" already exists` (created on first DDL pass)

These are **safe to ignore** as long as the smoke queries in §6 pass. If you want a
zero-error restore, follow §3d.

### 3c. Single-DB restore

If only one `db_<token>` is gone:

```bash
TOKEN="da17c47e-..."
KEY="postgres-customers/instant-customers-backup-2026-05-20T030048Z.sql.gz"

# Pull the dump locally:
AWS_ACCESS_KEY_ID="$SPACES_AK" AWS_SECRET_ACCESS_KEY="$SPACES_SK" AWS_DEFAULT_REGION=nyc3 \
  aws s3 cp s3://instant-pg-backups/${KEY} /tmp/restore.sql.gz \
  --endpoint-url=https://nyc3.digitaloceanspaces.com

# pg_dumpall produces a single SQL stream with per-database \connect statements.
# Extract only the section for db_${TOKEN}:
gunzip -c /tmp/restore.sql.gz | \
  awk -v tgt="\\connect db_${TOKEN}" '
    $0 == tgt { found=1; print; next }
    found && /^\\connect/ { exit }
    found
  ' > /tmp/restore-single.sql

POD=$(kubectl get pod -n instant-data -l app=postgres-customers -o name | head -1)
# Recreate the empty DB first, then load:
kubectl exec -n instant-data "$POD" -- \
  sh -c "PGPASSWORD=\$POSTGRES_PASSWORD psql -U instant_cust -d postgres \
    -c 'DROP DATABASE IF EXISTS db_${TOKEN}; CREATE DATABASE db_${TOKEN};'"

cat /tmp/restore-single.sql | \
  kubectl exec -i -n instant-data "$POD" -- \
    sh -c "PGPASSWORD=\$POSTGRES_PASSWORD psql -U instant_cust -d db_${TOKEN}"
```

### 3d. Cleanest path: restore into a parallel pod, then cut over

For zero-downtime / zero-error restores, prefer this shape:

```bash
# 1. Stand up a parallel pod with the same image, mounted on a fresh PVC.
# 2. pg_dumpall the existing pod's data → archive it (a fresh ad-hoc backup, not
#    one of the nightly ones).
# 3. psql the backup of step 2's data into the parallel pod.
# 4. Verify (§6).
# 5. Update the `postgres-customers` Service selector to point at the parallel
#    pod's labels.
# 6. Wait for connection drain, then delete the old pod.
```

This is identical to what the drill does, just with traffic eventually pointed at the
restored pod. The drill script is the template — `--keep-ns` leaves the sidecar pod alive
for you to point a Service at if you want.

---

## 4. Restore in anger — mongodb

```bash
# 0. Identify the artifact.
SPACES_AK=$(kubectl get secret spaces-backup-creds -n instant-data \
  -o jsonpath='{.data.OBJECT_STORE_ACCESS_KEY}' | base64 -d)
SPACES_SK=$(kubectl get secret spaces-backup-creds -n instant-data \
  -o jsonpath='{.data.OBJECT_STORE_SECRET_KEY}' | base64 -d)
KEY="mongodb/mongodb-backup-2026-05-20T030137Z.archive.gz"

# 1. ANNOUNCE the maintenance window.

# 2. Scale prod mongo to 0 to stop new writes:
kubectl scale -n instant-data deploy/mongodb --replicas=0
kubectl wait -n instant-data --for=delete pod -l app=mongodb --timeout=120s

# 3. Snapshot the prod PV (DO console / doctl). Record snapshot ID.

# 4. Bring mongo back up — it will load whatever is on the PV (still the
#    old state). Real recovery options:
#
#    OPTION A (data is gone, PV is empty): mongorestore directly into the live
#      pod, using --drop. The empty cluster has nothing to drop, so this is safe.
#    OPTION B (some bad writes — selective restore): pull the archive locally,
#      use `mongorestore --nsInclude='db_<token>.*'` to restore only one tenant.

kubectl scale -n instant-data deploy/mongodb --replicas=1
kubectl wait -n instant-data --for=condition=Ready pod -l app=mongodb --timeout=120s

# 5. Stream the archive into the running pod:
POD=$(kubectl get pod -n instant-data -l app=mongodb -o name | head -1)
AWS_ACCESS_KEY_ID="$SPACES_AK" AWS_SECRET_ACCESS_KEY="$SPACES_SK" AWS_DEFAULT_REGION=nyc3 \
  aws s3 cp s3://instant-pg-backups/${KEY} /tmp/restore.archive.gz \
  --endpoint-url=https://nyc3.digitaloceanspaces.com

kubectl cp /tmp/restore.archive.gz instant-data/${POD#pod/}:/tmp/restore.archive.gz

kubectl exec -n instant-data "$POD" -- \
  mongorestore --archive=/tmp/restore.archive.gz --gzip --drop \
    --username root --password root --authenticationDatabase=admin

# 6. Smoke (§6).
```

For single-tenant restore: swap step 5 for `mongorestore ... --nsInclude='db_<token>.*'`.

---

## 5. Restore in anger — redis-provision

Redis-provision **is treated as a soft-state cache**. There is no recommended restore
into prod, because the legitimate failure mode is "the pod restarts, the cache is
warm-loadable from the platform DB (resources table) + per-customer redis pods, and
everything self-heals within hours." The nightly RDB snapshot exists for forensic
inspection only.

If you need to inspect a historical snapshot:

```bash
KEY="redis-provision/redis-provision-backup-2026-05-20T030021Z.rdb.gz"
AWS_ACCESS_KEY_ID="$SPACES_AK" AWS_SECRET_ACCESS_KEY="$SPACES_SK" AWS_DEFAULT_REGION=nyc3 \
  aws s3 cp s3://instant-pg-backups/${KEY} /tmp/dump.rdb.gz \
  --endpoint-url=https://nyc3.digitaloceanspaces.com
gunzip /tmp/dump.rdb.gz
# Spin up a throwaway redis pod and load:
kubectl run redis-inspect --rm -i --restart=Never \
  --image=redis:7-alpine -- \
  sh -c 'redis-server --dir /tmp & sleep 1 && cat > /tmp/dump.rdb && redis-cli SHUTDOWN NOSAVE; redis-server --dir /tmp &
         sleep 1 && redis-cli KEYS "*" | head -20' < /tmp/dump.rdb
```

If you genuinely need to restore the prod redis-provision PV, treat it as a stateful
volume swap: snapshot the PV, scale the pod to 0, load the .rdb file into the PV, scale
back. Same shape as Postgres §3 but with `--restore-rdb` semantics.

---

## 6. Smoke-test queries — run after EVERY restore

### Postgres-customers

```sql
-- a) number of per-customer DBs restored (expect: matches prod day-before count)
SELECT COUNT(*) FROM pg_database WHERE datname LIKE 'db_%' ESCAPE '\\';

-- b) pool_items row count (expect: > 100 in healthy state; was 528 on 2026-05-20)
SELECT COUNT(*) FROM pool_items;

-- c) sample customer DB is queryable (pick any one):
\c db_<token>
SELECT 1;

-- d) recent provisioned resources are present (cross-check against api's
--    /api/v1/resources output for a known account):
SELECT datname FROM pg_database WHERE datname LIKE 'db_%' ESCAPE '\\' ORDER BY datname DESC LIMIT 5;
```

A restore where (a) returns 0 or (b) returns 0 is a **failed restore** — do NOT cut
over. Roll back to the PV snapshot taken in §3 step 3.

### MongoDB

```javascript
// a) non-system databases (expect: matches prod day-before count; was 1 on 2026-05-20)
db.adminCommand({listDatabases: 1}).databases
  .filter(d => !["admin","config","local"].includes(d.name))
  .map(d => d.name)

// b) pool DB has data:
use db_pool_<one of the names from (a)>
db.getCollectionNames()
// expect: at least one collection

// c) per-tenant DB sample:
use db_<token>
db.getCollectionNames()
```

---

## 7. Rollback (discard a botched restore)

The PV snapshot you took in step 3 is the rollback target. Procedure:

```bash
# 1. Scale the prod pod to 0:
kubectl scale -n instant-data deploy/postgres-customers --replicas=0   # or deploy/mongodb

# 2. Delete the PVC (this releases the PV but does NOT delete the PV if reclaimPolicy=Retain;
#    on DOKS the default is Delete, so for safety, edit the PV first and set
#    persistentVolumeReclaimPolicy: Retain BEFORE deleting the PVC):
kubectl get pv  # find the PV name
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl delete pvc -n instant-data <pvc-name>

# 3. Restore the snapshot:
#    Via DigitalOcean console / doctl, create a new volume from the snapshot.
#    Attach that volume's CSI volume handle to a new PV.
#    Bind a new PVC to it.

# 4. Scale the pod back up; it picks up the snapshot's contents.
kubectl scale -n instant-data deploy/postgres-customers --replicas=1
```

If you skipped the PV snapshot in step 3, the rollback target is the previous nightly
backup. Same procedure as §3, just with a different `KEY=`. This means you lose up to 24h
of writes — the actual RPO.

---

## 8. RPO / RTO numbers (measured 2026-05-20)

| Service | RPO (artifact age @ drill) | RTO (restore + smoke) | Smoke result |
|---|---|---|---|
| postgres-customers | 20864 s (5h 47m) | **93 s** | 121 db_* DBs, 528 pool_items rows |
| mongodb | 21038 s (5h 50m) | **42 s** | 1 non-system DB (matches prod) |

Interpretation:

* **RPO is bounded by schedule.** Backups run at 03:00 UTC daily, so worst-case RPO is
  **24h - epsilon**. The 5h45m measured here is just "how old is the most recent backup
  *right now*" at the time we ran the drill (we ran at ~08:50 UTC). At the worst possible
  moment (02:59 UTC, the minute before the next backup fires), the latest backup is ~24h
  old.
* **RTO is bounded by RPO + restore wall-clock.** Measured restore wall-clock for the
  current data size is ~90s (Postgres) and ~45s (Mongo). That is the **lower bound** —
  it does not include the cutover steps (scale-to-zero, PV snapshot, traffic re-route,
  smoke-test, declare end-of-incident). In a real incident, budget **15-30 minutes total
  RTO** for either service. At current data sizes (~150 KiB dump). RTO scales roughly
  linearly with dump size — at the current per-day growth rate the prod restore should
  stay under 30 min for the next 6+ months.

**Promised to customers (Pro tier marketing):** the public messaging says "automatic
backups", with no SLO numbers attached. The numbers above are the current internal SLO.
If we ever publish backup SLOs externally, re-run the drill at scale (10× data) before
committing to RPO/RTO values.

---

## 9. Trigger conditions — when to run §3 / §4 in anger

* `postgres-customers` pod is in `CrashLoopBackOff` after a node failure AND the PV
  contents are corrupt (verified via `pg_isready` + a sample `SELECT`).
* `mongodb` pod is in `CrashLoopBackOff` AND `mongod --repair` doesn't fix it.
* A customer reports a specific `db_<token>` is missing AND we can confirm it via
  `kubectl exec -n instant-data deploy/postgres-customers -- psql -U instant_cust -lqt`.
* DigitalOcean reports volume loss / region outage on the volume backing
  `postgres-customers` or `mongodb`.
* A bad migration was applied and it dropped/destroyed data. Single-DB restore (§3c).
* The Prometheus rule `BackupCronJobStale60h` or NR alert `backup-stale-36h` has
  already fired; you're recovering from a backup-pipeline outage AND a data event.

For the **scheduled monthly drill** (no live incident), use `infra/scripts/restore-drill.sh`
— it exercises the same code path but into a throwaway namespace.

---

## 10. Monitoring

| Layer | Alert | Source | Fires at |
|---|---|---|---|
| New Relic (live today) | [`backup-stale-36h.json`](newrelic/alerts/backup-stale-36h.json) | NR log stream — looks for `backup OK` line from the CronJob | WARNING at 36h with no success line; CRITICAL at 60h. FACETed per backup service. |
| Prometheus (declared; activates when kube-state-metrics is installed) | `BackupCronJobStale36h` / `BackupCronJobStale60h` / `BackupCronJobFailedLastRun` in [`k8s/prometheus-rules.yaml`](k8s/prometheus-rules.yaml) (group `instant-backups`) | `kube_cronjob_status_last_successful_time` + `kube_job_status_failed` | WARNING at >36h gap; CRITICAL at >60h gap. |
| Ad-hoc | `kubectl get cronjobs -n instant-data` | k8s control plane | Manual check; the `LAST SCHEDULE` column should never be older than 24h. |

We deliberately chose log-driven NR over a worker Go job — the CronJobs already emit the
success line `[<ts>] backup OK` (grep'd live from prod CronJob log on 2026-05-20), so no
new code is needed, no new failure mode introduced. A dedicated worker job would be
strictly more ops overhead.

---

## 11. Known gaps + improvements backlog (P1, not blocking)

| Item | Why it matters | Effort |
|---|---|---|
| **No off-site / off-bucket copy of backups.** If the `instant-pg-backups` Spaces bucket is lost (DO account compromise, billing-suspension, region failure), the entire backup tier is gone. | Promise of durability is single-region single-vendor. | Add a secondary CronJob that rclone-syncs the same dumps to a second provider (R2 / B2). Half a day. |
| **No backup-integrity test in CI.** The drill is manual / monthly. A regression in the backup script could go undetected for ~30 days. | Pre-detection. | Run `restore-drill.sh --service=postgres-customers` against a *staging* bucket from CI nightly. Half a day. |
| **`redis-provision-backup` has no documented restore plan.** §5 above says "soft state, don't restore in anger." If that ever changes (real session/state in redis-provision), it needs a real recovery path. | Forward-looking. | Decide retention semantics + add §5 detail. 1-2 hours. |
| **No row-count baseline tracked.** Smoke checks "pool_items > 0" but the baseline (528) drifts; today's drill measures it, future drills should compare against a stored baseline. | Catch silent partial-restore failures. | Add a `--baseline=<path>` flag to the drill that compares against a snapshot file. 1-2 hours. |
| **PV snapshot step (§3 step 3) is manual.** It's the only way to roll back a botched restore. | Operator step is easy to skip under pressure. | Add a `pre-restore-snapshot.sh` helper that wraps `doctl compute volume-action snapshot`. 1-2 hours. |
| **Backup creds are a long-lived Spaces master key.** Stored in `instant-data/spaces-backup-creds`. Rotation has never happened. | Standard secret-hygiene risk. | Rotate annually; document in NATS-AUTH-RUNBOOK-style flow. 1 hour. |

---

## 12. Drill Log

| Date | Operator | Postgres RPO/RTO | Mongo RPO/RTO | Outcome | Notes |
|---|---|---|---|---|---|
| 2026-05-20 | first-time drill (this PR) | 20864s / 93s | 21038s / 42s | **PASS** | Caught: (a) `amazon/aws-cli` image is distroless → broke `kubectl cp`, switched to `alpine + apk add aws-cli`. (b) `postgres:16-alpine` lacks `vector` extension → emitted 246 noisy ERROR lines on restore (didn't break smoke); switched sidecar image to prod-matching `pgvector/pgvector:pg16`. |

Update this table after every drill.
