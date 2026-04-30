#!/usr/bin/env bash
# Migrate all non-system databases from a MongoDB server to PostgreSQL via FerretDB.
#
# Usage:
#   migrate.sh --source-mongo <uri> --ferretdb <uri> [--target-postgres <uri>] [--databases <db1,db2,...>] [--skip-verify]
#
# The FerretDB instance must already be running and connected to the target PostgreSQL.
# When --target-postgres is provided, the script ensures the database exists and has
# the DocumentDB extension installed before starting the migration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP_DIR=""
RESULT_DIR=""
SOURCE_MONGO=""
FERRETDB=""
TARGET_POSTGRES=""
ONLY_DATABASES=""
SKIP_VERIFY=false

usage() {
  echo "Usage: $0 --source-mongo <uri> --ferretdb <uri> [--target-postgres <uri>] [--databases <db1,db2,...>] [--skip-verify]"
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
    --databases)     ONLY_DATABASES="$2";  shift 2 ;;
    --skip-verify)   SKIP_VERIFY=true;    shift ;;
    *)               usage ;;
  esac
done

[[ -z "$SOURCE_MONGO" ]] && { echo "ERROR: --source-mongo is required" >&2; usage; }
[[ -z "$FERRETDB" ]]     && { echo "ERROR: --ferretdb is required" >&2; usage; }

# ── Check prerequisites ──────────────────────────────────────────────────────
REQUIRED_CMDS=(mongosh mongodump mongorestore)
[[ -n "$TARGET_POSTGRES" ]] && REQUIRED_CMDS+=(psql)

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed or not on PATH." >&2
    exit 1
  fi
done

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

migrate_db() {
  local db="$1"
  echo ""
  echo "── Migrating: $db ──"
  if "$SCRIPT_DIR/scripts/dump-database.sh" "$SOURCE_MONGO" "$db" "$DUMP_DIR"; then
    if "$SCRIPT_DIR/scripts/restore-database.sh" "$FERRETDB" "$db" "$DUMP_DIR"; then
      touch "$RESULT_DIR/$db.ok"
      return 0
    else
      echo "ERROR: Restore failed for database '$db'" >&2
    fi
  else
    echo "ERROR: Dump failed for database '$db'" >&2
  fi
  touch "$RESULT_DIR/$db.fail"
  return 1
}

PIDS=()
for db in "${DATABASES[@]}"; do
  migrate_db "$db" &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

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
