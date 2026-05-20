#!/usr/bin/env bash
# =============================================================================
# restore-drill.sh — Verify that the nightly Postgres + MongoDB backups can
# ACTUALLY be restored. Pro-tier marketing promises backups; this is the
# control-plane evidence that the promise is kept.
#
# How it works:
#   1. Pulls the most-recent artifact from s3://instant-pg-backups/<svc>/
#   2. Creates a throwaway namespace `restore-drill-<unix-ts>`
#   3. Spins up a sidecar pod (`postgres:16-alpine` / `mongo:7.0`) with EMPTY
#      storage — NEVER touches the prod postgres-customers / mongodb pods.
#   4. Streams the dump into the sidecar via kubectl exec.
#   5. Runs smoke queries — row counts on the known prod-shape tables /
#      collections — and FAILS LOUD if the dump produces unexpected zeros.
#   6. Prints RPO (age of artifact when restore began) + RTO (wall-clock
#      seconds from sidecar-create to smoke-query-passed).
#   7. Deletes the throwaway namespace (and therefore the sidecar pod /
#      ephemeral storage) unless --keep-ns is passed.
#
# Safety contract:
#   - kube-context MUST be `do-nyc3-instant-prod` (asserted, not assumed).
#   - The sidecar pod runs in a namespace that does NOT exist on the cluster
#     until this script creates it. There is no path from sidecar to the prod
#     postgres-customers / mongodb services — they're in `instant-data` ns
#     and the sidecar never connects to them, only restores into itself.
#   - --service= picks postgres-customers | mongodb | all (default: all).
#   - exit code = first non-zero RC of any service drill.
#
# Usage:
#   bash infra/scripts/restore-drill.sh                    # both services
#   bash infra/scripts/restore-drill.sh --service=postgres-customers
#   bash infra/scripts/restore-drill.sh --service=mongodb
#   bash infra/scripts/restore-drill.sh --keep-ns          # don't tear down (debug)
#
# Required cluster prerequisites:
#   - Secret `instant-data/spaces-backup-creds` (already present in prod).
#   - kubectl with permission to create/delete namespaces, pods, configmaps.
#
# Companion runbook: infra/BACKUP-RESTORE-RUNBOOK.md
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

EXPECTED_CONTEXT="do-nyc3-instant-prod"
SOURCE_NS="instant-data"                  # where prod data + spaces creds live
BACKUP_BUCKET="instant-pg-backups"
SPACES_ENDPOINT_FALLBACK="nyc3.digitaloceanspaces.com"

# Must MATCH the prod image (`kubectl get deploy postgres-customers -n
# instant-data -o jsonpath='{.spec.template.spec.containers[*].image}'`).
# postgres:16-alpine lacks `vector` extension, which causes hundreds of
# benign-but-noisy ERROR lines on restore. pgvector/pgvector:pg16 mirrors prod.
PG_IMAGE="pgvector/pgvector:pg16"
MONGO_IMAGE="mongo:7.0"
# NB: amazon/aws-cli is distroless (no tar/sh), which breaks `kubectl cp`.
# We use the alpine variant — `alpine:3.20` + `apk add aws-cli` — for the
# transient helper pods. Heavier on cold-start by ~5s vs. distroless aws-cli
# but lets us `kubectl cp` and `kubectl exec sh -c '...'` reliably.
AWSCLI_IMAGE="alpine:3.20"

DRILL_NS="restore-drill-$(date -u +%s)"
KEEP_NS=0
SERVICE_FILTER="all"

# -----------------------------------------------------------------------------
# Args
# -----------------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --keep-ns) KEEP_NS=1 ;;
    --service=*) SERVICE_FILTER="${arg#--service=}" ;;
    --help|-h)
      sed -n '1,40p' "$0"
      exit 0 ;;
    *) echo "unknown arg: $arg"; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { printf '[%s] FATAL: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------

CTX="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$CTX" != "$EXPECTED_CONTEXT" ]]; then
  fail "kube-context is '$CTX' (expected '$EXPECTED_CONTEXT'). Refusing to run drill on the wrong cluster."
fi

if ! kubectl get secret spaces-backup-creds -n "$SOURCE_NS" >/dev/null 2>&1; then
  fail "Secret '${SOURCE_NS}/spaces-backup-creds' not found — backups upload from this secret; drill cannot read."
fi

if ! kubectl get secret instant-data-secrets -n "$SOURCE_NS" >/dev/null 2>&1; then
  log "WARN: instant-data-secrets not found — Postgres smoke query may use default creds"
fi

# Spaces creds (read once, masked in logs)
SPACES_AK="$(kubectl get secret spaces-backup-creds -n "$SOURCE_NS" -o jsonpath='{.data.OBJECT_STORE_ACCESS_KEY}' | base64 -d)"
SPACES_SK="$(kubectl get secret spaces-backup-creds -n "$SOURCE_NS" -o jsonpath='{.data.OBJECT_STORE_SECRET_KEY}' | base64 -d)"
SPACES_REGION="$(kubectl get secret spaces-backup-creds -n "$SOURCE_NS" -o jsonpath='{.data.OBJECT_STORE_REGION}' | base64 -d)"
SPACES_EP="$(kubectl get secret spaces-backup-creds -n "$SOURCE_NS" -o jsonpath='{.data.OBJECT_STORE_ENDPOINT}' | base64 -d || true)"
SPACES_EP="${SPACES_EP:-$SPACES_ENDPOINT_FALLBACK}"

if [[ -z "$SPACES_AK" || -z "$SPACES_SK" ]]; then
  fail "spaces-backup-creds secret is missing OBJECT_STORE_ACCESS_KEY / OBJECT_STORE_SECRET_KEY"
fi

# Mongo creds (the prod CronJob hardcodes root/root in env — match that)
MONGO_USER="root"
MONGO_PASS="root"

# Postgres customer password (so smoke can hit the restored DB in the sidecar)
PG_PASS="restoredrillpw$(date +%s)"   # local sidecar password — never used outside this ns

# -----------------------------------------------------------------------------
# Teardown (always runs)
# -----------------------------------------------------------------------------

teardown() {
  local rc=$?
  if [[ "$KEEP_NS" == "1" ]]; then
    log "--keep-ns set; leaving namespace $DRILL_NS intact for inspection."
    log "Clean up later: kubectl delete ns $DRILL_NS"
    exit $rc
  fi
  log "Tearing down namespace $DRILL_NS ..."
  kubectl delete ns "$DRILL_NS" --wait=false --ignore-not-found=true >/dev/null 2>&1 || true
  exit $rc
}
trap teardown EXIT

# -----------------------------------------------------------------------------
# Create throwaway namespace
# -----------------------------------------------------------------------------

log "Creating throwaway namespace: $DRILL_NS"
kubectl create namespace "$DRILL_NS" >/dev/null

# Copy the Spaces creds into the drill namespace (so the awscli pod can read them).
kubectl create secret generic spaces-creds \
  -n "$DRILL_NS" \
  --from-literal=AWS_ACCESS_KEY_ID="$SPACES_AK" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SPACES_SK" \
  --from-literal=AWS_DEFAULT_REGION="$SPACES_REGION" \
  --from-literal=SPACES_ENDPOINT="$SPACES_EP" \
  >/dev/null

# -----------------------------------------------------------------------------
# Helper: find the latest backup object for a given prefix.
# Writes the object KEY (e.g. "postgres-customers/instant-customers-backup-...sql.gz")
# and SIZE (bytes) + LASTMOD (UTC ISO8601) to stdout, one space-separated line.
# -----------------------------------------------------------------------------

find_latest_backup() {
  local prefix="$1"
  # Create a one-shot Job (deterministic, no rm-race), wait, then read its log.
  # Output line from `aws s3 ls`: "YYYY-MM-DD HH:MM:SS  <size>  <filename>"
  local jobname="find-${prefix//[._]/-}-$RANDOM"
  kubectl create -n "$DRILL_NS" -f - <<JSON >/dev/null
{
  "apiVersion": "batch/v1",
  "kind": "Job",
  "metadata": {"name": "${jobname}"},
  "spec": {
    "backoffLimit": 0,
    "ttlSecondsAfterFinished": 60,
    "template": {
      "spec": {
        "restartPolicy": "Never",
        "containers": [{
          "name": "find",
          "image": "${AWSCLI_IMAGE}",
          "envFrom": [{"secretRef": {"name": "spaces-creds"}}],
          "command": ["/bin/sh","-c","apk add --no-cache aws-cli >/dev/null 2>&1 && aws s3 ls s3://${BACKUP_BUCKET}/${prefix}/ --endpoint-url=https://\${SPACES_ENDPOINT} 2>&1 | sort | tail -1"]
        }]
      }
    }
  }
}
JSON
  kubectl wait --for=condition=complete --timeout=60s -n "$DRILL_NS" "job/${jobname}" >/dev/null 2>&1 || {
    echo "Job ${jobname} did not complete; logs follow:" >&2
    kubectl logs -n "$DRILL_NS" "job/${jobname}" >&2 || true
    return 1
  }
  local raw
  raw=$(kubectl logs -n "$DRILL_NS" "job/${jobname}" 2>/dev/null | tail -1)
  kubectl delete job -n "$DRILL_NS" "${jobname}" --wait=false >/dev/null 2>&1 || true
  # raw = "YYYY-MM-DD HH:MM:SS  <size>  <filename>"
  echo "$raw" | awk '{ printf "%s %s %sT%sZ\n", $4, $3, $1, $2 }'
}

# -----------------------------------------------------------------------------
# Helper: download a backup object into a sidecar pod's /tmp via an init pod.
# Strategy: launch the sidecar with a "long-running" placeholder command so we
# can kubectl cp into it; download to /tmp on the LOCAL drill machine via a
# transient awscli pod, then kubectl cp into the sidecar.
# -----------------------------------------------------------------------------

# Local working dir for the drill (the dump is also kept here for forensics).
WORKDIR="$(mktemp -d -t restore-drill-XXXXXX)"
log "Local workdir: $WORKDIR"

download_backup_locally() {
  local key="$1" outfile="$2"
  log "Downloading s3://${BACKUP_BUCKET}/${key} -> ${outfile}"
  # Strategy: start a long-running awscli pod, kubectl exec into it to do the
  # download into the pod's /tmp, then kubectl cp it out. This avoids the
  # well-known "kubectl run --rm -i" stdout-interleaving pitfalls for binary
  # streams (and we get deterministic exit codes from the exec).
  local podname="dl-${RANDOM}-${RANDOM}"
  kubectl create -n "$DRILL_NS" -f - <<JSON >/dev/null
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "${podname}"},
  "spec": {
    "restartPolicy": "Never",
    "containers": [{
      "name": "dl",
      "image": "${AWSCLI_IMAGE}",
      "envFrom": [{"secretRef": {"name": "spaces-creds"}}],
      "command": ["sh","-c","apk add --no-cache aws-cli >/dev/null 2>&1 && sleep 600"]
    }]
  }
}
JSON
  kubectl wait --for=condition=Ready --timeout=60s -n "$DRILL_NS" "pod/${podname}" >/dev/null
  # Wait an extra moment for aws-cli install to finish (apk add is in the
  # container's command, but Ready fires before the sleep starts).
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if kubectl exec -n "$DRILL_NS" "${podname}" -- which aws >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! kubectl exec -n "$DRILL_NS" "${podname}" -- \
        sh -c "aws s3 cp s3://${BACKUP_BUCKET}/${key} /tmp/dump.bin --endpoint-url=https://\${SPACES_ENDPOINT} --no-progress" \
        >/dev/null 2>&1; then
    kubectl logs -n "$DRILL_NS" "${podname}" >&2 || true
    kubectl delete pod -n "$DRILL_NS" "${podname}" --wait=false >/dev/null 2>&1 || true
    fail "aws s3 cp failed for ${key}"
  fi
  # Copy out of the pod (alpine has busybox tar, kubectl cp works).
  kubectl cp "$DRILL_NS/${podname}:/tmp/dump.bin" "$outfile" >/dev/null
  kubectl delete pod -n "$DRILL_NS" "${podname}" --wait=false >/dev/null 2>&1 || true

  local sz
  sz=$(wc -c < "$outfile" | tr -d ' ')
  log "Downloaded ${sz} bytes -> ${outfile}"
  if [[ "$sz" -lt 1024 ]]; then
    fail "downloaded file is <1KB — corrupt or stream broke"
  fi
}

# -----------------------------------------------------------------------------
# POSTGRES DRILL
# -----------------------------------------------------------------------------

drill_postgres() {
  log "=========================================================="
  log "postgres-customers restore drill — starting"
  log "=========================================================="

  # 1. Find latest backup
  local prefix="postgres-customers"
  local listing
  listing="$(find_latest_backup "$prefix")"
  [[ -z "$listing" ]] && fail "no backup objects found under s3://${BACKUP_BUCKET}/${prefix}/"
  local key size lastmod
  key="${prefix}/$(echo "$listing" | awk '{print $1}')"
  size="$(echo "$listing" | awk '{print $2}')"
  lastmod="$(echo "$listing" | awk '{print $3}')"

  log "latest: ${key}"
  log "size:   ${size} bytes"
  log "stamped at S3: ${lastmod}"

  # 2. Compute RPO: artifact age (now - lastmod)
  local now_epoch lastmod_epoch rpo_seconds rpo_hms
  now_epoch=$(date -u +%s)
  # The S3 listing time format from `aws s3 ls` is "YYYY-MM-DD HH:MM:SS" UTC.
  # We rebuilt as "YYYY-MM-DDTHH:MM:SSZ" already.
  lastmod_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$lastmod" +%s 2>/dev/null || date -u -d "$lastmod" +%s 2>/dev/null || echo 0)
  rpo_seconds=$(( now_epoch - lastmod_epoch ))
  rpo_hms="$(printf '%dh %dm %ds' $((rpo_seconds/3600)) $(((rpo_seconds%3600)/60)) $((rpo_seconds%60)))"
  log "RPO (artifact age):      ${rpo_seconds}s (${rpo_hms})"

  # 3. Start wall-clock for RTO
  local rto_start
  rto_start=$(date -u +%s)

  # 4. Download backup locally
  local dump="${WORKDIR}/pg.sql.gz"
  download_backup_locally "$key" "$dump"

  # 5. Launch sidecar Postgres (empty)
  log "starting sidecar postgres pod (image: $PG_IMAGE)"
  kubectl run pg-restore-sidecar \
    -n "$DRILL_NS" \
    --image="$PG_IMAGE" \
    --restart=Never \
    --env="POSTGRES_PASSWORD=$PG_PASS" \
    --env="POSTGRES_USER=instant_cust" \
    --env="POSTGRES_DB=instant_customers" \
    --port=5432 \
    --command -- docker-entrypoint.sh postgres >/dev/null

  log "waiting for sidecar to be Ready ..."
  kubectl wait --for=condition=Ready --timeout=120s pod/pg-restore-sidecar -n "$DRILL_NS" >/dev/null

  # 6. Wait for actual pg_isready (Ready != accepting connections)
  for i in $(seq 1 30); do
    if kubectl exec -n "$DRILL_NS" pg-restore-sidecar -- pg_isready -U instant_cust >/dev/null 2>&1; then
      log "postgres accepting connections (after ${i}s of pg_isready polls)"
      break
    fi
    sleep 1
    [[ "$i" == 30 ]] && fail "sidecar postgres did not become ready in 30s"
  done

  # 7. Stream the gzipped dump into psql in the sidecar
  log "streaming dump into sidecar via psql (--clean --if-exists already in dump)"
  if ! gunzip -c "$dump" | \
      kubectl exec -i -n "$DRILL_NS" pg-restore-sidecar -- \
        sh -c "PGPASSWORD=\"$PG_PASS\" psql -U instant_cust -d instant_customers -v ON_ERROR_STOP=0" \
        > "${WORKDIR}/pg-restore.log" 2>&1; then
    log "WARN: psql exit was non-zero — examining log"
  fi
  local errcount
  errcount=$(grep -cE '^(ERROR|FATAL|PANIC):' "${WORKDIR}/pg-restore.log" || true)
  if [[ "$errcount" -gt 0 ]]; then
    log "psql logged ${errcount} ERROR/FATAL lines (first 10):"
    grep -E '^(ERROR|FATAL|PANIC):' "${WORKDIR}/pg-restore.log" | head -10 | sed 's/^/    /'
  fi
  # NOTE: pg_dumpall with --clean --if-exists ALWAYS produces some non-zero
  # ERRORs on a fresh empty cluster (DROP ROLE / DROP DATABASE on non-existent
  # objects, statements with --if-exists that still print a notice in some
  # cases, etc.). We don't gate on errcount > 0 — we gate on the smoke
  # query producing real data.

  # 8. Smoke query — count databases + count rows in `pool_items`.
  log "running smoke queries"
  local dbs poolcount
  dbs=$(kubectl exec -n "$DRILL_NS" pg-restore-sidecar -- \
        sh -c "PGPASSWORD=\"$PG_PASS\" psql -U instant_cust -d instant_customers -tAc \"SELECT COUNT(*) FROM pg_database WHERE datname LIKE 'db\\_%' ESCAPE '\\\\'\"" 2>&1 | tr -d ' ')
  poolcount=$(kubectl exec -n "$DRILL_NS" pg-restore-sidecar -- \
        sh -c "PGPASSWORD=\"$PG_PASS\" psql -U instant_cust -d instant_customers -tAc 'SELECT COUNT(*) FROM pool_items'" 2>&1 | tr -d ' ')
  log "  smoke: db_* databases restored = ${dbs}"
  log "  smoke: pool_items row count    = ${poolcount}"

  if ! [[ "$dbs" =~ ^[0-9]+$ ]] || [[ "$dbs" -lt 1 ]]; then
    fail "smoke FAIL: expected >=1 db_* database in restored cluster (got '$dbs')"
  fi
  if ! [[ "$poolcount" =~ ^[0-9]+$ ]] || [[ "$poolcount" -lt 1 ]]; then
    fail "smoke FAIL: expected >=1 pool_items row in restored cluster (got '$poolcount')"
  fi

  # 9. RTO
  local rto_end rto_seconds
  rto_end=$(date -u +%s)
  rto_seconds=$(( rto_end - rto_start ))
  log "RTO (restore + smoke):   ${rto_seconds}s"
  log "DRILL postgres-customers: PASS"
  log ""

  # Stash result for the summary line
  PG_RPO_S=$rpo_seconds
  PG_RTO_S=$rto_seconds
  PG_OBJECT="$key"
  PG_DBS="$dbs"
  PG_POOLITEMS="$poolcount"
}

# -----------------------------------------------------------------------------
# MONGO DRILL
# -----------------------------------------------------------------------------

drill_mongo() {
  log "=========================================================="
  log "mongodb restore drill — starting"
  log "=========================================================="

  local prefix="mongodb"
  local listing
  listing="$(find_latest_backup "$prefix")"
  [[ -z "$listing" ]] && fail "no backup objects found under s3://${BACKUP_BUCKET}/${prefix}/"
  local key size lastmod
  key="${prefix}/$(echo "$listing" | awk '{print $1}')"
  size="$(echo "$listing" | awk '{print $2}')"
  lastmod="$(echo "$listing" | awk '{print $3}')"

  log "latest: ${key}"
  log "size:   ${size} bytes"
  log "stamped at S3: ${lastmod}"

  local now_epoch lastmod_epoch rpo_seconds rpo_hms
  now_epoch=$(date -u +%s)
  lastmod_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$lastmod" +%s 2>/dev/null || date -u -d "$lastmod" +%s 2>/dev/null || echo 0)
  rpo_seconds=$(( now_epoch - lastmod_epoch ))
  rpo_hms="$(printf '%dh %dm %ds' $((rpo_seconds/3600)) $(((rpo_seconds%3600)/60)) $((rpo_seconds%60)))"
  log "RPO (artifact age):      ${rpo_seconds}s (${rpo_hms})"

  local rto_start
  rto_start=$(date -u +%s)

  local dump="${WORKDIR}/mongo.archive.gz"
  download_backup_locally "$key" "$dump"

  log "starting sidecar mongo pod (image: $MONGO_IMAGE)"
  kubectl run mongo-restore-sidecar \
    -n "$DRILL_NS" \
    --image="$MONGO_IMAGE" \
    --restart=Never \
    --env="MONGO_INITDB_ROOT_USERNAME=$MONGO_USER" \
    --env="MONGO_INITDB_ROOT_PASSWORD=$MONGO_PASS" \
    --port=27017 \
    --command -- docker-entrypoint.sh mongod --bind_ip_all >/dev/null

  log "waiting for sidecar to be Ready ..."
  kubectl wait --for=condition=Ready --timeout=120s pod/mongo-restore-sidecar -n "$DRILL_NS" >/dev/null

  for i in $(seq 1 60); do
    if kubectl exec -n "$DRILL_NS" mongo-restore-sidecar -- \
        mongosh --quiet -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
        --eval "db.runCommand({ ping: 1 }).ok" 2>/dev/null | grep -q 1; then
      log "mongo accepting connections (after ${i}s of ping polls)"
      break
    fi
    sleep 1
    [[ "$i" == 60 ]] && fail "sidecar mongo did not become ready in 60s"
  done

  # Copy archive INTO the sidecar pod, then mongorestore from local file
  # (kubectl exec -i piped streams have a bad reputation with binary protos).
  log "copying archive into sidecar pod"
  kubectl cp "$dump" "$DRILL_NS/mongo-restore-sidecar:/tmp/restore.archive.gz"

  log "running mongorestore --archive=/tmp/restore.archive.gz --gzip --drop"
  if ! kubectl exec -n "$DRILL_NS" mongo-restore-sidecar -- \
      mongorestore --archive=/tmp/restore.archive.gz --gzip --drop \
        --username "$MONGO_USER" \
        --password "$MONGO_PASS" \
        --authenticationDatabase=admin \
        > "${WORKDIR}/mongo-restore.log" 2>&1; then
    log "mongorestore exited non-zero — log tail:"
    tail -20 "${WORKDIR}/mongo-restore.log" | sed 's/^/    /'
    fail "mongorestore failed"
  fi
  log "mongorestore OK"

  # Smoke: count databases (excluding system DBs).
  local dbnames dbcount
  dbnames=$(kubectl exec -n "$DRILL_NS" mongo-restore-sidecar -- \
      mongosh --quiet -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
      --eval 'db.adminCommand({listDatabases:1}).databases.filter(d => !["admin","config","local"].includes(d.name)).map(d => d.name).join(",")' 2>&1 | tail -1 | tr -d ' ')
  if [[ -z "$dbnames" ]]; then
    dbcount=0
  else
    dbcount=$(echo "$dbnames" | tr ',' '\n' | wc -l | tr -d ' ')
  fi
  log "  smoke: non-system databases restored = ${dbcount} (${dbnames})"

  if [[ "$dbcount" -lt 1 ]]; then
    fail "smoke FAIL: expected >=1 non-system mongo database (got 0)"
  fi

  local rto_end rto_seconds
  rto_end=$(date -u +%s)
  rto_seconds=$(( rto_end - rto_start ))
  log "RTO (restore + smoke):   ${rto_seconds}s"
  log "DRILL mongodb: PASS"
  log ""

  MONGO_RPO_S=$rpo_seconds
  MONGO_RTO_S=$rto_seconds
  MONGO_OBJECT="$key"
  MONGO_DBS="$dbcount"
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

PG_RPO_S=
PG_RTO_S=
PG_OBJECT=
PG_DBS=
PG_POOLITEMS=
MONGO_RPO_S=
MONGO_RTO_S=
MONGO_OBJECT=
MONGO_DBS=

case "$SERVICE_FILTER" in
  postgres-customers|postgres|pg) drill_postgres ;;
  mongodb|mongo)                  drill_mongo ;;
  all)                            drill_postgres; drill_mongo ;;
  *) fail "unknown --service value: $SERVICE_FILTER (use postgres-customers | mongodb | all)" ;;
esac

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

log "=========================================================="
log "RESTORE DRILL SUMMARY ($(date -u +%FT%TZ))"
log "=========================================================="
log "cluster:           ${EXPECTED_CONTEXT}"
log "drill namespace:   ${DRILL_NS} (teardown=$([[ $KEEP_NS == 1 ]] && echo skipped || echo done))"
if [[ -n "$PG_OBJECT" ]]; then
  log ""
  log "postgres-customers:"
  log "  artifact:        s3://${BACKUP_BUCKET}/${PG_OBJECT}"
  log "  RPO:             ${PG_RPO_S}s"
  log "  RTO:             ${PG_RTO_S}s"
  log "  smoke db_* count:  ${PG_DBS}"
  log "  smoke pool_items:  ${PG_POOLITEMS}"
fi
if [[ -n "$MONGO_OBJECT" ]]; then
  log ""
  log "mongodb:"
  log "  artifact:        s3://${BACKUP_BUCKET}/${MONGO_OBJECT}"
  log "  RPO:             ${MONGO_RPO_S}s"
  log "  RTO:             ${MONGO_RTO_S}s"
  log "  smoke non-system DBs: ${MONGO_DBS}"
fi
log ""
log "RESULT: PASS"
