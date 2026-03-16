#!/usr/bin/env bash
# Verify that migrated data matches source by comparing document counts.
# Usage: verify-migration.sh <source-uri> <ferretdb-uri> [db1 db2 ...]
# If no database names are given, all non-system databases on the source are checked.
set -euo pipefail

SOURCE_URI="${1:?Usage: verify-migration.sh <source-uri> <ferretdb-uri> [db ...]}"
FERRETDB_URI="${2:?Missing ferretdb-uri}"
shift 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Collect database list
if [[ $# -gt 0 ]]; then
  DATABASES=("$@")
else
  DATABASES=()
  while IFS= read -r _db; do
    [[ -n "$_db" ]] && DATABASES+=("$_db")
  done < <("$SCRIPT_DIR/list-databases.sh" "$SOURCE_URI")
fi

ERRORS=0

for db in "${DATABASES[@]}"; do
  echo "--- Verifying database: $db ---"

  # Get collections from source
  COLLECTIONS=$(mongosh --quiet --norc "$SOURCE_URI" --eval "
    db.getSiblingDB('$db').getCollectionNames().forEach(c => print(c));
  ")

  if [[ -z "$COLLECTIONS" ]]; then
    echo "  (no collections)"
    continue
  fi

  while IFS= read -r coll; do
    [[ -z "$coll" ]] && continue
    SRC_COUNT=$(mongosh --quiet --norc "$SOURCE_URI" --eval "
      print(db.getSiblingDB('$db').getCollection('$coll').countDocuments());
    ")
    DST_COUNT=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
      print(db.getSiblingDB('$db').getCollection('$coll').countDocuments());
    ")

    # Trim whitespace
    SRC_COUNT=$(echo "$SRC_COUNT" | tr -d '[:space:]')
    DST_COUNT=$(echo "$DST_COUNT" | tr -d '[:space:]')

    if [[ "$SRC_COUNT" == "$DST_COUNT" ]]; then
      echo "  $db.$coll: OK ($SRC_COUNT documents)"
    else
      echo "  $db.$coll: MISMATCH — source=$SRC_COUNT, target=$DST_COUNT" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done <<< "$COLLECTIONS"
done

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "VERIFICATION FAILED: $ERRORS mismatches found." >&2
  exit 1
fi

echo "VERIFICATION PASSED: All document counts match."
