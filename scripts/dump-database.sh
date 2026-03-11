#!/usr/bin/env bash
# Dump a single MongoDB database using mongodump.
# Usage: dump-database.sh <source-uri> <db-name> <output-dir>
set -euo pipefail

SOURCE_URI="${1:?Usage: dump-database.sh <source-uri> <db-name> <output-dir>}"
DB_NAME="${2:?Missing db-name}"
OUTPUT_DIR="${3:?Missing output-dir}"

echo "Dumping database '$DB_NAME' ..."
mongodump --uri="$SOURCE_URI" --db="$DB_NAME" --out="$OUTPUT_DIR" --quiet
echo "Dump complete: $OUTPUT_DIR/$DB_NAME"
