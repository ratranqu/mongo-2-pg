#!/usr/bin/env bash
# Restore a single database dump into FerretDB (which writes to PostgreSQL).
# Usage: restore-database.sh <ferretdb-uri> <db-name> <dump-dir>
set -euo pipefail

FERRETDB_URI="${1:?Usage: restore-database.sh <ferretdb-uri> <db-name> <dump-dir>}"
DB_NAME="${2:?Missing db-name}"
DUMP_DIR="${3:?Missing dump-dir}"

MAX_RETRIES=3
RETRY_DELAY=5

DUMP_PATH="$DUMP_DIR/$DB_NAME"
if [[ ! -d "$DUMP_PATH" ]]; then
  echo "ERROR: Dump directory not found: $DUMP_PATH" >&2
  exit 1
fi

echo "Restoring database '$DB_NAME' into FerretDB ..."

for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  if mongorestore --uri="$FERRETDB_URI" --nsInclude="${DB_NAME}.*" --dir="$DUMP_DIR" 2>&1; then
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
