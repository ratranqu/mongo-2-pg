#!/usr/bin/env bash
# Stream a single database from MongoDB to FerretDB via mongodump --archive | mongorestore --archive.
# Eliminates temp disk usage by piping directly.
# Usage: stream-database.sh <source-uri> <ferretdb-uri> <db-name> [parallel-collections] [insertion-workers]
set -euo pipefail

SOURCE_URI="${1:?Usage: stream-database.sh <source-uri> <ferretdb-uri> <db-name> [parallel-collections] [insertion-workers]}"
FERRETDB_URI="${2:?Missing ferretdb-uri}"
DB_NAME="${3:?Missing db-name}"
PARALLEL_COLLECTIONS="${4:-4}"
INSERTION_WORKERS="${5:-4}"

MAX_RETRIES=3
RETRY_DELAY=5

echo "Streaming database '$DB_NAME' (source → FerretDB) ..."

for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  if mongodump --uri="$SOURCE_URI" --db="$DB_NAME" --archive --gzip \
       --numParallelCollections="$PARALLEL_COLLECTIONS" --quiet 2>&1 | \
     mongorestore --uri="$FERRETDB_URI" --archive --gzip --db="$DB_NAME" \
       --numParallelCollections="$PARALLEL_COLLECTIONS" \
       --numInsertionWorkersPerCollection="$INSERTION_WORKERS" 2>&1; then
    echo "Stream complete for '$DB_NAME'"
    exit 0
  fi

  if [[ $attempt -lt $MAX_RETRIES ]]; then
    echo "WARNING: Stream attempt $attempt/$MAX_RETRIES failed for '$DB_NAME', retrying in ${RETRY_DELAY}s ..." >&2
    sleep "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))
  fi
done

echo "ERROR: Stream failed for '$DB_NAME' after $MAX_RETRIES attempts" >&2
exit 1
