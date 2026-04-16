#!/bin/bash
set -e

# Resolve the directory containing this script so it can be run from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "$SCRIPT_DIR/namespace.yaml"

# Data layer (must come before infra services that depend on it)
kubectl apply -f "$SCRIPT_DIR/data/"

# Secrets
kubectl apply -f "$SCRIPT_DIR/secrets.yaml"        # instant namespace secrets
kubectl apply -f "$SCRIPT_DIR/infra-secrets.yaml"  # instant-infra namespace secrets

# Platform (API)
kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/migrations-configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/postgres-platform.yaml"
kubectl apply -f "$SCRIPT_DIR/redis.yaml"
kubectl apply -f "$SCRIPT_DIR/app.yaml"
kubectl apply -f "$SCRIPT_DIR/website.yaml"

# Infra services
kubectl apply -f "$SCRIPT_DIR/provisioner/"
kubectl apply -f "$SCRIPT_DIR/worker/"
kubectl apply -f "$SCRIPT_DIR/migrator/"
