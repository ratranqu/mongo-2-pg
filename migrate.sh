#!/usr/bin/env bash
# Migrate all non-system databases from a MongoDB server to PostgreSQL via FerretDB.
#
# Usage:
#   migrate.sh --source-mongo <uri> --ferretdb <uri> [--target-postgres <uri>] [--skip-verify]
#
# The FerretDB instance must already be running and connected to the target PostgreSQL.
# --target-postgres is informational/optional (used for direct PG verification if desired).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP_DIR=""
SOURCE_MONGO=""
FERRETDB=""
TARGET_POSTGRES=""
SKIP_VERIFY=false

usage() {
  echo "Usage: $0 --source-mongo <uri> --ferretdb <uri> [--target-postgres <uri>] [--skip-verify]"
  exit 1
}

cleanup() {
  if [[ -n "$DUMP_DIR" && -d "$DUMP_DIR" ]]; then
    echo "Cleaning up dump directory: $DUMP_DIR"
    rm -rf "$DUMP_DIR"
  fi
}
trap cleanup EXIT

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-mongo)  SOURCE_MONGO="$2";   shift 2 ;;
    --ferretdb)      FERRETDB="$2";       shift 2 ;;
    --target-postgres) TARGET_POSTGRES="$2"; shift 2 ;;
    --skip-verify)   SKIP_VERIFY=true;    shift ;;
    *)               usage ;;
  esac
done

[[ -z "$SOURCE_MONGO" ]] && { echo "ERROR: --source-mongo is required" >&2; usage; }
[[ -z "$FERRETDB" ]]     && { echo "ERROR: --ferretdb is required" >&2; usage; }

# ── Check prerequisites ──────────────────────────────────────────────────────
for cmd in mongosh mongodump mongorestore; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed or not on PATH." >&2
    exit 1
  fi
done

# ── List databases ────────────────────────────────────────────────────────────
echo "=== Discovering databases on source MongoDB ==="
mapfile -t DATABASES < <("$SCRIPT_DIR/scripts/list-databases.sh" "$SOURCE_MONGO")

if [[ ${#DATABASES[@]} -eq 0 ]]; then
  echo "No user databases found on source. Nothing to migrate."
  exit 0
fi

echo "Found ${#DATABASES[@]} database(s): ${DATABASES[*]}"

# ── Dump & Restore ────────────────────────────────────────────────────────────
DUMP_DIR=$(mktemp -d -t mongo-dump-XXXXXX)
echo ""
echo "=== Starting migration ==="
echo "Dump directory: $DUMP_DIR"

MIGRATED=0
FAILED=0

for db in "${DATABASES[@]}"; do
  echo ""
  echo "── Migrating: $db ──"

  if "$SCRIPT_DIR/scripts/dump-database.sh" "$SOURCE_MONGO" "$db" "$DUMP_DIR"; then
    if "$SCRIPT_DIR/scripts/restore-database.sh" "$FERRETDB" "$db" "$DUMP_DIR"; then
      MIGRATED=$((MIGRATED + 1))
    else
      echo "ERROR: Restore failed for database '$db'" >&2
      FAILED=$((FAILED + 1))
    fi
  else
    echo "ERROR: Dump failed for database '$db'" >&2
    FAILED=$((FAILED + 1))
  fi
done

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
