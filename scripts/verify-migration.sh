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
VERIFY_TMP=$(mktemp -d -t mongo-verify-XXXXXX)
trap 'rm -rf "$VERIFY_TMP"' EXIT

# Collect all counts in two mongosh calls (one per side) instead of per-collection
mongosh --quiet --norc "$SOURCE_URI" --eval "
  const dbs = [$(printf "'%s'," "${DATABASES[@]}" | sed 's/,$//')]
  dbs.forEach(dbName => {
    const d = db.getSiblingDB(dbName);
    d.getCollectionNames().forEach(c => {
      print(dbName + '\t' + c + '\t' + d.getCollection(c).estimatedDocumentCount());
    });
  });
" > "$VERIFY_TMP/src_counts" &

mongosh --quiet --norc "$FERRETDB_URI" --eval "
  const dbs = [$(printf "'%s'," "${DATABASES[@]}" | sed 's/,$//')]
  dbs.forEach(dbName => {
    const d = db.getSiblingDB(dbName);
    d.getCollectionNames().forEach(c => {
      print(dbName + '\t' + c + '\t' + d.getCollection(c).estimatedDocumentCount());
    });
  });
" > "$VERIFY_TMP/dst_counts" &

wait

# Build associative lookups and compare
declare -A SRC_COUNTS DST_COUNTS ALL_KEYS DB_COLLS
while IFS=$'\t' read -r _db _coll _count; do
  [[ -z "$_db" ]] && continue
  SRC_COUNTS["${_db}.${_coll}"]="$_count"
  ALL_KEYS["${_db}.${_coll}"]=1
  DB_COLLS["$_db"]+="${_coll}"$'\n'
done < "$VERIFY_TMP/src_counts"

while IFS=$'\t' read -r _db _coll _count; do
  [[ -z "$_db" ]] && continue
  DST_COUNTS["${_db}.${_coll}"]="$_count"
  ALL_KEYS["${_db}.${_coll}"]=1
  DB_COLLS["$_db"]+="${_coll}"$'\n'
done < "$VERIFY_TMP/dst_counts"

for db in "${DATABASES[@]}"; do
  echo "--- Verifying database: $db ---"
  _colls="${DB_COLLS[$db]:-}"
  if [[ -z "$_colls" ]]; then
    echo "  (no collections)"
    continue
  fi

  while IFS= read -r coll; do
    [[ -z "$coll" ]] && continue
    _key="${db}.${coll}"
    _src="${SRC_COUNTS[$_key]:-0}"
    _dst="${DST_COUNTS[$_key]:-0}"

    if [[ "$_src" == "$_dst" ]]; then
      echo "  $_key: OK ($_src documents)"
    else
      echo "  $_key: MISMATCH — source=$_src, target=$_dst" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done <<< "$(echo "$_colls" | sort -u)"
done

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "VERIFICATION FAILED: $ERRORS mismatches found." >&2
  exit 1
fi

echo "VERIFICATION PASSED: All document counts match."
