#!/usr/bin/env bash
# End-to-end test for MongoDB → PostgreSQL migration via FerretDB.
#
# Assumes:
#   - A Kubernetes cluster is available (kubectl configured)
#   - mongosh, mongodump, mongorestore, psql are on PATH
#
# Usage: e2e-test.sh [--no-cleanup]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="mongo2pg-test"
CLEANUP=true

if [[ "${1:-}" == "--no-cleanup" ]]; then
  CLEANUP=false
fi

# Port-forward PIDs for cleanup
PF_PIDS=()

cleanup() {
  echo ""
  echo "=== Cleaning up ==="

  # Kill port-forwards
  for pid in "${PF_PIDS[@]+"${PF_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done

  if [[ "$CLEANUP" == "true" ]]; then
    echo "Deleting namespace $NAMESPACE ..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
  else
    echo "Skipping cleanup (--no-cleanup). Resources remain in namespace: $NAMESPACE"
  fi
}
trap cleanup EXIT

wait_for_port() {
  local host="$1" port="$2" label="$3" retries="${4:-30}"
  echo "  Waiting for $label ($host:$port) ..."
  for ((i=1; i<=retries; i++)); do
    if bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
      echo "  $label: ready"
      return 0
    fi
    sleep 1
  done
  echo "  ERROR: $label not reachable after ${retries}s" >&2
  return 1
}

# ── 1. Create namespace and deploy ────────────────────────────────────────────
echo "=== Setting up test environment in namespace: $NAMESPACE ==="

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Apply test manifests with kustomize
echo "Applying kustomize manifests ..."
kubectl apply -k "$PROJECT_DIR/k8s/test/" -n "$NAMESPACE"

echo "Resources applied. Current state:"
kubectl get all -n "$NAMESPACE" 2>/dev/null || true

# ── 2. Wait for pods to be ready ─────────────────────────────────────────────
echo ""
echo "=== Waiting for pods ==="

echo "Waiting for PostgreSQL (DocumentDB extension init can be slow) ..."
kubectl wait --for=condition=ready pod -l app=postgres -n "$NAMESPACE" --timeout=600s

echo "Waiting for source MongoDB ..."
kubectl wait --for=condition=ready pod -l app=source-mongodb -n "$NAMESPACE" --timeout=300s

echo "Waiting for FerretDB ..."
kubectl wait --for=condition=ready pod -l app=ferretdb -n "$NAMESPACE" --timeout=300s

echo "All pods ready:"
kubectl get pods -n "$NAMESPACE"

# ── 3. Wait for seed job ─────────────────────────────────────────────────────
echo ""
echo "=== Waiting for seed job to complete ==="
kubectl wait --for=condition=complete job/seed-mongodb -n "$NAMESPACE" --timeout=300s
echo "Seed job completed."

# Show seed logs
echo "--- Seed job logs ---"
kubectl logs job/seed-mongodb -n "$NAMESPACE" --all-containers || true
echo "---------------------"

# ── 4. Set up port-forwards ──────────────────────────────────────────────────
echo ""
echo "=== Setting up port-forwards ==="

# Source MongoDB → localhost:27117
kubectl port-forward svc/source-mongodb 27117:27017 -n "$NAMESPACE" &
PF_PIDS+=($!)

# FerretDB → localhost:27217
kubectl port-forward svc/ferretdb 27217:27017 -n "$NAMESPACE" &
PF_PIDS+=($!)

# PostgreSQL → localhost:25432
kubectl port-forward svc/postgres 25432:5432 -n "$NAMESPACE" &
PF_PIDS+=($!)

# Wait for port-forwards to be reachable
wait_for_port localhost 27117 "Source MongoDB"
wait_for_port localhost 27217 "FerretDB"
wait_for_port localhost 25432 "PostgreSQL"

# Verify application-level connectivity
echo "Verifying application connectivity ..."
mongosh --quiet --norc "mongodb://localhost:27117" --eval 'print("ping:" + db.runCommand({ping:1}).ok)'
echo "  Source MongoDB: OK"
mongosh --quiet --norc "mongodb://ferretdb:ferretdb@localhost:27217" --eval 'print("ping:" + db.runCommand({ping:1}).ok)'
echo "  FerretDB: OK"
psql "postgresql://ferretdb:ferretdb@localhost:25432/postgres" -c "SELECT 1;" >/dev/null
echo "  PostgreSQL: OK"

# ── 5. Run migration ─────────────────────────────────────────────────────────
echo ""
echo "=== Running migration ==="

"$PROJECT_DIR/migrate.sh" \
  --source-mongo "mongodb://localhost:27117" \
  --ferretdb "mongodb://ferretdb:ferretdb@localhost:27217" \
  --target-postgres "postgresql://ferretdb:ferretdb@localhost:25432/postgres" \
  --max-concurrent 3

# ── 6. Validate results ──────────────────────────────────────────────────────
echo ""
echo "=== Validating results ==="

"$SCRIPT_DIR/validate.sh" \
  "postgresql://ferretdb:ferretdb@localhost:25432/postgres" \
  "mongodb://ferretdb:ferretdb@localhost:27217"

echo ""
echo "============================================"
echo "  END-TO-END TEST PASSED"
echo "============================================"
