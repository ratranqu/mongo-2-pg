#!/usr/bin/env bash
# Restore a single database dump into FerretDB (which writes to PostgreSQL) or a
# real MongoDB server. The caller decides parallel-collections: pass 1 for FerretDB
# (it races on parallel collection creation) or any value for real MongoDB.
# Usage: restore-database.sh <target-uri> <db-name> <dump-dir> [parallel-collections] [insertion-workers] [collections]
set -euo pipefail

TARGET_URI="${1:?Usage: restore-database.sh <target-uri> <db-name> <dump-dir> [parallel-collections] [insertion-workers] [collections]}"
DB_NAME="${2:?Missing db-name}"
DUMP_DIR="${3:?Missing dump-dir}"
PARALLEL_COLLECTIONS="${4:-1}"
INSERTION_WORKERS="${5:-4}"
COLLECTIONS="${6:-}"

MAX_RETRIES=3
RETRY_DELAY=5

DUMP_PATH="$DUMP_DIR/$DB_NAME"
if [[ ! -d "$DUMP_PATH" ]]; then
  echo "ERROR: Dump directory not found: $DUMP_PATH" >&2
  exit 1
fi

# Build --nsInclude args and collection list for targeted restore
NS_ARGS=()
COLL_LIST=()
if [[ -n "$COLLECTIONS" ]]; then
  IFS=',' read -ra COLL_LIST <<< "$COLLECTIONS"
  for c in "${COLL_LIST[@]}"; do
    NS_ARGS+=(--nsInclude="${DB_NAME}.${c}")
  done
  echo "Restoring ${#COLL_LIST[@]} collection(s) into '$DB_NAME' ..."
else
  echo "Restoring database '$DB_NAME' ..."
fi

# FerretDB/DocumentDB's dropDatabase() doesn't always clean up catalog entries,
# leaving stale metadata that points to non-existent PostgreSQL tables.
# Drop every collection individually first, then drop the database.
drop_target() {
  if [[ ${#COLL_LIST[@]} -gt 0 ]]; then
    local coll_js
    coll_js=$(printf "'%s'," "${COLL_LIST[@]}" | sed 's/,$//')
    mongosh --quiet --norc "$TARGET_URI" --eval "
      const d = db.getSiblingDB('$DB_NAME');
      [$coll_js].forEach(c => { d.getCollection(c).drop(); });
    " 2>/dev/null || true
  else
    mongosh --quiet --norc "$TARGET_URI" --eval "
      const d = db.getSiblingDB('$DB_NAME');
      d.getCollectionNames().forEach(c => { d.getCollection(c).drop(); });
      d.dropDatabase();
    " 2>/dev/null || true
  fi
}

drop_target

for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  if [[ ${#NS_ARGS[@]} -gt 0 ]]; then
    if mongorestore --uri="$TARGET_URI" --dir="$DUMP_DIR" \
         "${NS_ARGS[@]}" \
         --numParallelCollections="$PARALLEL_COLLECTIONS" \
         --numInsertionWorkersPerCollection="$INSERTION_WORKERS" --gzip 2>&1; then
      echo "Restore complete for '$DB_NAME' (${#COLL_LIST[@]} collection(s))"
      exit 0
    fi
  else
    if mongorestore --uri="$TARGET_URI" --db="$DB_NAME" --dir="$DUMP_PATH" \
         --numParallelCollections="$PARALLEL_COLLECTIONS" \
         --numInsertionWorkersPerCollection="$INSERTION_WORKERS" --gzip 2>&1; then
      echo "Restore complete for '$DB_NAME'"
      exit 0
    fi
  fi

  if [[ $attempt -lt $MAX_RETRIES ]]; then
    echo "WARNING: Restore attempt $attempt/$MAX_RETRIES failed for '$DB_NAME', retrying in ${RETRY_DELAY}s ..." >&2
    sleep "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))
    drop_target
  fi
done

echo "ERROR: Restore failed for '$DB_NAME' after $MAX_RETRIES attempts" >&2
exit 1
