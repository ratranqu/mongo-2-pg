#!/usr/bin/env bash
# Dump a single MongoDB database using mongodump.
# Usage: dump-database.sh <source-uri> <db-name> <output-dir> [parallel-collections] [collections]
set -euo pipefail

SOURCE_URI="${1:?Usage: dump-database.sh <source-uri> <db-name> <output-dir> [parallel-collections] [collections]}"
DB_NAME="${2:?Missing db-name}"
OUTPUT_DIR="${3:?Missing output-dir}"
PARALLEL_COLLECTIONS="${4:-4}"
COLLECTIONS="${5:-}"

if [[ -n "$COLLECTIONS" ]]; then
  IFS=',' read -ra COLL_LIST <<< "$COLLECTIONS"
  echo "Dumping ${#COLL_LIST[@]} collection(s) from '$DB_NAME' ..."
  for c in "${COLL_LIST[@]}"; do
    mongodump --uri="$SOURCE_URI" --db="$DB_NAME" --collection="$c" \
      --out="$OUTPUT_DIR" --gzip --quiet
  done
else
  echo "Dumping database '$DB_NAME' ..."
  mongodump --uri="$SOURCE_URI" --db="$DB_NAME" --out="$OUTPUT_DIR" \
    --numParallelCollections="$PARALLEL_COLLECTIONS" --gzip --quiet
fi
echo "Dump complete: $OUTPUT_DIR/$DB_NAME"
