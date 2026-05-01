#!/usr/bin/env bash
# Stream a single database from MongoDB to a target (FerretDB or MongoDB) via
# mongodump --archive | mongorestore --archive. Eliminates temp disk usage.
# The caller decides restore-parallel-collections: pass 1 for FerretDB (it races
# on parallel collection creation) or any value for real MongoDB.
# Usage: stream-database.sh <source-uri> <target-uri> <db-name> [parallel-collections] [insertion-workers] [restore-parallel-collections]
set -euo pipefail

SOURCE_URI="${1:?Usage: stream-database.sh <source-uri> <target-uri> <db-name> [parallel-collections] [insertion-workers] [restore-parallel-collections]}"
TARGET_URI="${2:?Missing target-uri}"
DB_NAME="${3:?Missing db-name}"
PARALLEL_COLLECTIONS="${4:-4}"
INSERTION_WORKERS="${5:-4}"
RESTORE_PARALLEL_COLLECTIONS="${6:-1}"

MAX_RETRIES=3
RETRY_DELAY=5

echo "Streaming database '$DB_NAME' (source → target) ..."

# FerretDB/DocumentDB's dropDatabase() doesn't always clean up catalog entries,
# leaving stale metadata that points to non-existent PostgreSQL tables.
# Drop every collection individually first, then drop the database.
drop_database() {
  mongosh --quiet --norc "$TARGET_URI" --eval "
    const d = db.getSiblingDB('$DB_NAME');
    d.getCollectionNames().forEach(c => { d.getCollection(c).drop(); });
    d.dropDatabase();
  " 2>/dev/null || true
}

drop_database

for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  if mongodump --uri="$SOURCE_URI" --db="$DB_NAME" --archive --gzip \
       --numParallelCollections="$PARALLEL_COLLECTIONS" --quiet 2>&1 | \
     mongorestore --uri="$TARGET_URI" --archive --gzip --db="$DB_NAME" \
       --numParallelCollections="$RESTORE_PARALLEL_COLLECTIONS" \
       --numInsertionWorkersPerCollection="$INSERTION_WORKERS" 2>&1; then
    echo "Stream complete for '$DB_NAME'"
    exit 0
  fi

  if [[ $attempt -lt $MAX_RETRIES ]]; then
    echo "WARNING: Stream attempt $attempt/$MAX_RETRIES failed for '$DB_NAME', retrying in ${RETRY_DELAY}s ..." >&2
    sleep "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))
    drop_database
  fi
done

echo "ERROR: Stream failed for '$DB_NAME' after $MAX_RETRIES attempts" >&2
exit 1
