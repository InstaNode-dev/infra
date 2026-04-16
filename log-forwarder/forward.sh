#!/bin/sh
# forward.sh — Tail k8s container logs (which Docker SD can't discover due to
# network_mode: container:<pod_id>) and write them to files Promtail can read.
#
# k8s containers share the pause container's network namespace, so they have no
# independent Docker network entry and are invisible to Promtail's docker_sd_configs.
# This sidecar bridges that gap using the Docker socket directly.

set -e

LOG_DIR=/k8s-logs
mkdir -p "$LOG_DIR"

# Follow a container matching the given grep pattern, writing stdout+stderr to logfile.
# Restarts automatically if the container is not found or exits (pod restarts).
follow_container() {
  local pattern="$1"
  local logfile="$2"

  while true; do
    local container
    container=$(docker ps --format '{{.Names}}' | grep "$pattern" | head -1)

    if [ -n "$container" ]; then
      echo "[forwarder] following $container → $logfile" >&2
      # --since 30s avoids re-emitting logs from before this forwarder started
      docker logs --follow --since 30s "$container" >> "$logfile" 2>&1 || true
      echo "[forwarder] $container exited or log stream closed, retrying…" >&2
    else
      echo "[forwarder] no container matching '$pattern', retrying in 5s…" >&2
    fi

    sleep 5
  done
}

echo "[forwarder] starting log forwarder for instant.dev k8s services" >&2

follow_container '^k8s_api_instant-api'          "$LOG_DIR/instant-api.log"          &
follow_container '^k8s_provisioner_instant-prov' "$LOG_DIR/instant-provisioner.log"  &
follow_container '^k8s_worker_instant-worker'    "$LOG_DIR/instant-worker.log"        &
follow_container '^k8s_migrator_instant-migr'    "$LOG_DIR/instant-migrator.log"      &

wait
