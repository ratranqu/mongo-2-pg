#!/usr/bin/env bash
# Stream a single database from MongoDB to a target (FerretDB or MongoDB) via
# mongodump --archive | mongorestore --archive. Eliminates temp disk usage.
#
# In stream mode dump and restore parallelism are coupled: mongorestore inherits
# the parallel collection count from the archive and silently ignores its own
# --numParallelCollections flag, so the dump must be produced at the rate the
# target can consume. Callers should pass 1 for FerretDB (it races on parallel
# collection creation) and any higher value only when the target is real MongoDB.
#
# Usage: stream-database.sh <source-uri> <target-uri> <db-name> [parallel-collections] [insertion-workers] [collections]
set -euo pipefail

SOURCE_URI="${1:?Usage: stream-database.sh <source-uri> <target-uri> <db-name> [parallel-collections] [insertion-workers] [collections]}"
TARGET_URI="${2:?Missing target-uri}"
DB_NAME="${3:?Missing db-name}"
PARALLEL_COLLECTIONS="${4:-1}"
INSERTION_WORKERS="${5:-4}"
COLLECTIONS="${6:-}"

MAX_RETRIES=3
RETRY_DELAY=5

COLL_LIST=()
if [[ -n "$COLLECTIONS" ]]; then
  IFS=',' read -ra COLL_LIST <<< "$COLLECTIONS"
  echo "Streaming ${#COLL_LIST[@]} collection(s) from '$DB_NAME' (source → target) ..."
else
  echo "Streaming database '$DB_NAME' (source → target) ..."
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

_stream_one_collection() {
  local coll="$1"
  local _retry_delay=$RETRY_DELAY
  for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
    if mongodump --uri="$SOURCE_URI" --db="$DB_NAME" --collection="$coll" --archive --gzip --quiet 2>&1 | \
       mongorestore --uri="$TARGET_URI" --archive --gzip --nsInclude="${DB_NAME}.${coll}" \
         --numParallelCollections=1 \
         --numInsertionWorkersPerCollection="$INSERTION_WORKERS" 2>&1; then
      return 0
    fi
    if [[ $attempt -lt $MAX_RETRIES ]]; then
      echo "WARNING: Stream attempt $attempt/$MAX_RETRIES failed for '$DB_NAME.$coll', retrying in ${_retry_delay}s ..." >&2
      sleep "$_retry_delay"
      _retry_delay=$((_retry_delay * 2))
    fi
  done
  return 1
}

drop_target

if [[ ${#COLL_LIST[@]} -gt 0 ]]; then
  for c in "${COLL_LIST[@]}"; do
    if ! _stream_one_collection "$c"; then
      echo "ERROR: Stream failed for '$DB_NAME.$c' after $MAX_RETRIES attempts" >&2
      exit 1
    fi
  done
  echo "Stream complete for '$DB_NAME' (${#COLL_LIST[@]} collection(s))"
  exit 0
fi

for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  if mongodump --uri="$SOURCE_URI" --db="$DB_NAME" --archive --gzip \
       --numParallelCollections="$PARALLEL_COLLECTIONS" --quiet 2>&1 | \
     mongorestore --uri="$TARGET_URI" --archive --gzip --db="$DB_NAME" \
       --numParallelCollections="$PARALLEL_COLLECTIONS" \
       --numInsertionWorkersPerCollection="$INSERTION_WORKERS" 2>&1; then
    echo "Stream complete for '$DB_NAME'"
    exit 0
  fi

  if [[ $attempt -lt $MAX_RETRIES ]]; then
    echo "WARNING: Stream attempt $attempt/$MAX_RETRIES failed for '$DB_NAME', retrying in ${RETRY_DELAY}s ..." >&2
    sleep "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))
    drop_target
  fi
done

echo "ERROR: Stream failed for '$DB_NAME' after $MAX_RETRIES attempts" >&2
exit 1
