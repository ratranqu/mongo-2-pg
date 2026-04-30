#!/usr/bin/env bash
# Migrate all non-system databases from a MongoDB server to PostgreSQL via FerretDB.
#
# Usage:
#   migrate.sh --source-mongo <uri> --ferretdb <uri> [--target-postgres <uri>] [--databases <db1,db2,...>] [--skip-verify]
#   migrate.sh --source-mongo <uri> --ferretdb <uri> --target-db <dbname> [--namespace <ns>] [--databases <db1,db2,...>] [--skip-verify]
#
# The FerretDB instance must already be running and connected to the target PostgreSQL.
# When --target-postgres is provided, the script ensures the database exists and has
# the DocumentDB extension installed before starting the migration.
# --target-db is a shorthand that builds the PostgreSQL URI from the ferretdb-postgres
# secret in the given namespace (default: current kubectl context namespace).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP_DIR=""
RESULT_DIR=""
SOURCE_MONGO=""
FERRETDB=""
TARGET_POSTGRES=""
TARGET_DB=""
NAMESPACE=""
ONLY_DATABASES=""
SKIP_VERIFY=false

usage() {
  echo "Usage: $0 --source-mongo <uri> --ferretdb <uri> [--target-postgres <uri> | --target-db <dbname> [--namespace <ns>]] [--databases <db1,db2,...>] [--skip-verify]"
  exit 1
}

cleanup() {
  if [[ -n "$DUMP_DIR" && -d "$DUMP_DIR" ]]; then
    echo "Cleaning up dump directory: $DUMP_DIR"
    rm -rf "$DUMP_DIR"
  fi
  [[ -n "$RESULT_DIR" && -d "$RESULT_DIR" ]] && rm -rf "$RESULT_DIR"
}
trap cleanup EXIT

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-mongo)  SOURCE_MONGO="$2";   shift 2 ;;
    --ferretdb)      FERRETDB="$2";       shift 2 ;;
    --target-postgres) TARGET_POSTGRES="$2"; shift 2 ;;
    --target-db)     TARGET_DB="$2";       shift 2 ;;
    --namespace)     NAMESPACE="$2";       shift 2 ;;
    --databases)     ONLY_DATABASES="$2";  shift 2 ;;
    --skip-verify)   SKIP_VERIFY=true;    shift ;;
    *)               usage ;;
  esac
done

[[ -z "$SOURCE_MONGO" ]] && { echo "ERROR: --source-mongo is required" >&2; usage; }
[[ -z "$FERRETDB" ]]     && { echo "ERROR: --ferretdb is required" >&2; usage; }

if [[ -n "$TARGET_DB" && -n "$TARGET_POSTGRES" ]]; then
  echo "ERROR: --target-db and --target-postgres are mutually exclusive" >&2
  usage
fi

# ── Check prerequisites ──────────────────────────────────────────────────────
REQUIRED_CMDS=(mongosh mongodump mongorestore)
[[ -n "$TARGET_DB" ]] && REQUIRED_CMDS+=(kubectl)
[[ -n "$TARGET_POSTGRES" || -n "$TARGET_DB" ]] && REQUIRED_CMDS+=(psql)

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed or not on PATH." >&2
    exit 1
  fi
done

# ── Build TARGET_POSTGRES from k8s secret if --target-db was given ──────────
if [[ -n "$TARGET_DB" ]]; then
  NS_ARGS=()
  [[ -n "$NAMESPACE" ]] && NS_ARGS=(-n "$NAMESPACE")

  echo "=== Reading PostgreSQL credentials from secret ferretdb-postgres ==="
  _get_field() { kubectl get secret ferretdb-postgres "${NS_ARGS[@]}" -o jsonpath="{.data.$1}" | base64 -d; }
  _pg_host=$(_get_field POSTGRES_HOST) || { echo "ERROR: Could not read secret ferretdb-postgres" >&2; exit 1; }
  _pg_port=$(_get_field POSTGRES_PORT)
  _pg_user=$(_get_field POSTGRES_USER)
  _pg_pass=$(_get_field POSTGRES_PASSWORD)

  TARGET_POSTGRES="postgresql://${_pg_user}:${_pg_pass}@${_pg_host}:${_pg_port}/${TARGET_DB}"
  echo "  Target PostgreSQL URI: postgresql://${_pg_user}:****@${_pg_host}:${_pg_port}/${TARGET_DB}"
fi

# ── Prepare target database ─────────────────────────────────────────────────
if [[ -n "$TARGET_POSTGRES" ]]; then
  echo "=== Preparing target PostgreSQL database ==="
  "$SCRIPT_DIR/scripts/prepare-target-db.sh" "$TARGET_POSTGRES"
  echo ""
fi

# ── List databases ────────────────────────────────────────────────────────────
echo "=== Discovering databases on source MongoDB ==="
DATABASES=()
while IFS= read -r _db; do
  [[ -n "$_db" ]] && DATABASES+=("$_db")
done < <("$SCRIPT_DIR/scripts/list-databases.sh" "$SOURCE_MONGO")

if [[ ${#DATABASES[@]} -eq 0 ]]; then
  echo "No user databases found on source. Nothing to migrate."
  exit 0
fi

echo "Found ${#DATABASES[@]} database(s): ${DATABASES[*]}"

# ── Filter databases if --databases was specified ────────────────────────────
if [[ -n "$ONLY_DATABASES" ]]; then
  IFS=',' read -ra REQUESTED <<< "$ONLY_DATABASES"
  FILTERED=()
  for req in "${REQUESTED[@]}"; do
    req="$(echo "$req" | xargs)"  # trim whitespace
    found=false
    for db in "${DATABASES[@]}"; do
      if [[ "$db" == "$req" ]]; then
        FILTERED+=("$req")
        found=true
        break
      fi
    done
    if [[ "$found" == "false" ]]; then
      echo "WARNING: Requested database '$req' not found on source, skipping." >&2
    fi
  done
  DATABASES=("${FILTERED[@]}")
  if [[ ${#DATABASES[@]} -eq 0 ]]; then
    echo "No matching databases to migrate."
    exit 0
  fi
  echo "Filtered to ${#DATABASES[@]} database(s): ${DATABASES[*]}"
fi

# ── Dump & Restore ────────────────────────────────────────────────────────────
DUMP_DIR=$(mktemp -d -t mongo-dump-XXXXXX)
echo ""
echo "=== Starting migration ==="
echo "Dump directory: $DUMP_DIR"

RESULT_DIR=$(mktemp -d -t mongo-results-XXXXXX)
MIGRATION_START=$(date +%s)

# Count source documents per database (in parallel)
for db in "${DATABASES[@]}"; do
  mongosh --quiet --norc "$SOURCE_MONGO" --eval "
    let total = 0;
    db.getSiblingDB('$db').getCollectionNames().forEach(c => {
      total += db.getSiblingDB('$db').getCollection(c).countDocuments();
    });
    print(total);
  " | tr -d '[:space:]' > "$RESULT_DIR/$db.doc_count" &
done
wait

# Phase 1: Dump all databases in parallel
echo ""
echo "── Phase 1: Dumping databases ──"
DUMP_PIDS=()
DUMP_START=$(date +%s)
for db in "${DATABASES[@]}"; do
  (
    _s=$(date +%s)
    "$SCRIPT_DIR/scripts/dump-database.sh" "$SOURCE_MONGO" "$db" "$DUMP_DIR"
    echo "$(( $(date +%s) - _s ))" > "$RESULT_DIR/$db.dump_time"
  ) &
  DUMP_PIDS+=($!)
done

for i in "${!DATABASES[@]}"; do
  if ! wait "${DUMP_PIDS[$i]}"; then
    echo "ERROR: Dump failed for database '${DATABASES[$i]}'" >&2
    touch "$RESULT_DIR/${DATABASES[$i]}.fail"
  fi
done
DUMP_END=$(date +%s)

# Record dump sizes
for db in "${DATABASES[@]}"; do
  [[ -d "$DUMP_DIR/$db" ]] && du -sb "$DUMP_DIR/$db" | cut -f1 > "$RESULT_DIR/$db.dump_size"
done

# Phase 2: Restore databases sequentially (FerretDB cannot handle concurrent restores)
echo ""
echo "── Phase 2: Restoring databases ──"
RESTORE_START=$(date +%s)
for db in "${DATABASES[@]}"; do
  [[ -f "$RESULT_DIR/$db.fail" ]] && continue
  echo ""
  echo "── Restoring: $db ──"
  _s=$(date +%s)
  if "$SCRIPT_DIR/scripts/restore-database.sh" "$FERRETDB" "$db" "$DUMP_DIR"; then
    touch "$RESULT_DIR/$db.ok"
  else
    echo "ERROR: Restore failed for database '$db'" >&2
    touch "$RESULT_DIR/$db.fail"
  fi
  echo "$(( $(date +%s) - _s ))" > "$RESULT_DIR/$db.restore_time"
done
RESTORE_END=$(date +%s)

MIGRATED=$(find "$RESULT_DIR" -name '*.ok' | wc -l)
FAILED=$(find "$RESULT_DIR" -name '*.fail' | wc -l)

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$SKIP_VERIFY" == "false" ]]; then
  echo "=== Verifying migration ==="
  "$SCRIPT_DIR/scripts/verify-migration.sh" "$SOURCE_MONGO" "$FERRETDB" "${DATABASES[@]}"
else
  echo "(Verification skipped)"
fi

# ── Statistics ────────────────────────────────────────────────────────────────
MIGRATION_END=$(date +%s)
echo ""
echo "=== Migration Statistics ==="
printf "%-32s %10s %10s %10s %12s\n" "Database" "Dump (MB)" "Documents" "Dump (s)" "Restore (s)"
printf "%-32s %10s %10s %10s %12s\n" "--------------------------------" "----------" "----------" "----------" "------------"

TOTAL_BYTES=0
TOTAL_DOCS=0
for db in "${DATABASES[@]}"; do
  _bytes=$(cat "$RESULT_DIR/$db.dump_size" 2>/dev/null || echo 0)
  _docs=$(cat "$RESULT_DIR/$db.doc_count" 2>/dev/null || echo 0)
  _dt=$(cat "$RESULT_DIR/$db.dump_time" 2>/dev/null || echo -)
  _rt=$(cat "$RESULT_DIR/$db.restore_time" 2>/dev/null || echo -)
  _mb=$(awk "BEGIN { printf \"%.1f\", $_bytes / 1048576 }")
  printf "%-32s %10s %10s %10s %12s\n" "$db" "$_mb" "$_docs" "${_dt}s" "${_rt}s"
  TOTAL_BYTES=$(( TOTAL_BYTES + _bytes ))
  TOTAL_DOCS=$(( TOTAL_DOCS + _docs ))
done

TOTAL_MB=$(awk "BEGIN { printf \"%.1f\", $TOTAL_BYTES / 1048576 }")
WALL_TIME=$(( MIGRATION_END - MIGRATION_START ))
printf "%-32s %10s %10s %10s %12s\n" "--------------------------------" "----------" "----------" "----------" "------------"
printf "%-32s %10s %10s %10s %12s\n" "TOTAL" "$TOTAL_MB" "$TOTAL_DOCS" "$((DUMP_END - DUMP_START))s" "$((RESTORE_END - RESTORE_START))s"

echo ""
echo "  Wall time:  ${WALL_TIME}s"
if [[ $WALL_TIME -gt 0 ]]; then
  echo "  Throughput: $(awk "BEGIN { printf \"%.1f\", $TOTAL_BYTES / 1048576 / $WALL_TIME }") MB/s, $(awk "BEGIN { printf \"%.0f\", $TOTAL_DOCS / $WALL_TIME }") docs/s"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Migration Summary ==="
echo "  Databases migrated: $MIGRATED"
echo "  Databases failed:   $FAILED"
echo "  Total:              ${#DATABASES[@]}"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi

echo ""
echo "Migration complete. Existing MongoDB clients can now connect to FerretDB at:"
echo "  $FERRETDB"
