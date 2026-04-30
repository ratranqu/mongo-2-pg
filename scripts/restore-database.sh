#!/usr/bin/env bash
# Restore a single database dump into FerretDB (which writes to PostgreSQL).
# Usage: restore-database.sh <ferretdb-uri> <db-name> <dump-dir> [parallel-collections] [insertion-workers]
set -euo pipefail

FERRETDB_URI="${1:?Usage: restore-database.sh <ferretdb-uri> <db-name> <dump-dir> [parallel-collections] [insertion-workers]}"
DB_NAME="${2:?Missing db-name}"
DUMP_DIR="${3:?Missing dump-dir}"
PARALLEL_COLLECTIONS="${4:-4}"
INSERTION_WORKERS="${5:-4}"

MAX_RETRIES=3
RETRY_DELAY=5

DUMP_PATH="$DUMP_DIR/$DB_NAME"
if [[ ! -d "$DUMP_PATH" ]]; then
  echo "ERROR: Dump directory not found: $DUMP_PATH" >&2
  exit 1
fi

echo "Restoring database '$DB_NAME' into FerretDB ..."

# Drop existing database to ensure clean state (handles stale metadata from previous runs)
mongosh --quiet --norc "$FERRETDB_URI" --eval "db.getSiblingDB('$DB_NAME').dropDatabase()" 2>/dev/null || true

for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  # FerretDB/DocumentDB races when creating multiple collections in parallel,
  # so always restore one collection at a time (numParallelCollections=1).
  if mongorestore --uri="$FERRETDB_URI" --db="$DB_NAME" --dir="$DUMP_PATH" \
       --numParallelCollections=1 \
       --numInsertionWorkersPerCollection="$INSERTION_WORKERS" --gzip 2>&1; then
    echo "Restore complete for '$DB_NAME'"
    exit 0
  fi

  if [[ $attempt -lt $MAX_RETRIES ]]; then
    echo "WARNING: Restore attempt $attempt/$MAX_RETRIES failed for '$DB_NAME', retrying in ${RETRY_DELAY}s ..." >&2
    sleep "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))
  fi
done

echo "ERROR: Restore failed for '$DB_NAME' after $MAX_RETRIES attempts" >&2
exit 1
