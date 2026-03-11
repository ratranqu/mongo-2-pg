#!/usr/bin/env bash
# Restore a single database dump into FerretDB (which writes to PostgreSQL).
# Usage: restore-database.sh <ferretdb-uri> <db-name> <dump-dir>
set -euo pipefail

FERRETDB_URI="${1:?Usage: restore-database.sh <ferretdb-uri> <db-name> <dump-dir>}"
DB_NAME="${2:?Missing db-name}"
DUMP_DIR="${3:?Missing dump-dir}"

DUMP_PATH="$DUMP_DIR/$DB_NAME"
if [[ ! -d "$DUMP_PATH" ]]; then
  echo "ERROR: Dump directory not found: $DUMP_PATH" >&2
  exit 1
fi

echo "Restoring database '$DB_NAME' into FerretDB ..."
mongorestore --uri="$FERRETDB_URI" --nsInclude="${DB_NAME}.*" --drop "$DUMP_PATH" --dir="$DUMP_DIR"
echo "Restore complete for '$DB_NAME'"
