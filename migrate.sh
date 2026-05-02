#!/usr/bin/env bash
# Migrate all non-system databases from a MongoDB server to either PostgreSQL via FerretDB
# or another MongoDB server.
#
# Usage:
#   migrate.sh --source-mongo <uri> (--ferretdb <uri> | --mongo <uri>) [options]
#
# When using --ferretdb, the FerretDB instance must already be running and connected to
# the target PostgreSQL. When using --mongo, the target is a real MongoDB server, so
# --parallel-collections is honored on restore (FerretDB requires it pinned to 1).
#
# Options:
#   --target-postgres <uri>    Ensure this PG database exists with DocumentDB extension
#   --target-db <dbname>       Same, but read credentials from ferretdb-postgres k8s secret
#   --admin-postgres <uri>     Optional superuser-equivalent URI used to CREATE
#                              EXTENSION and GRANT documentdb_admin_role to the
#                              target user. Required when --target-postgres /
#                              --target-db credentials are not a superuser.
#   --namespace <ns>           Kubernetes namespace for --target-db secret lookup
#   --databases <db1,db2,...>  Only migrate these databases
#   --collections <c1,c2,...>  Only migrate these collections (requires exactly one --databases)
#   --stream                   Pipe mongodump directly to mongorestore (no temp disk)
#   --max-concurrent <n>       Max databases to migrate concurrently (default: 1, or 2 with --stream)
#   --parallel-collections <n> Collections to dump/restore in parallel per DB (default: 4).
#                              On restore, only honored when --mongo is used (FerretDB pins to 1).
#                              In --stream mode, dump and restore are coupled (mongorestore
#                              inherits parallelism from the archive), so the value used is
#                              the restore-side one (1 against FerretDB, --parallel-collections
#                              against --mongo).
#   --insertion-workers <n>    Insertion workers per collection during restore (default: 4)
#   --clean-target             Purge stale DocumentDB catalog entries before migrating
#   --skip-verify              Skip post-migration verification
#   --progress-interval <sec>  Poll target every N seconds and print
#                              percentage/throughput/ETA per database (default: 30,
#                              0 disables)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP_DIR=""
RESULT_DIR=""
SOURCE_MONGO=""
FERRETDB=""
MONGO_TARGET=""
TARGET_IS_MONGO=false
TARGET_POSTGRES=""
TARGET_DB=""
ADMIN_POSTGRES=""
NAMESPACE=""
ONLY_DATABASES=""
ONLY_COLLECTIONS=""
STREAM=false
MAX_CONCURRENT=""
PARALLEL_COLLECTIONS=4
INSERTION_WORKERS=4
SKIP_VERIFY=false
CLEAN_TARGET=false
PROGRESS_INTERVAL=30

usage() {
  echo "Usage: $0 --source-mongo <uri> (--ferretdb <uri> | --mongo <uri>) [--stream] [--max-concurrent <n>] [--parallel-collections <n>] [--insertion-workers <n>] [--target-postgres <uri> | --target-db <dbname> [--namespace <ns>]] [--admin-postgres <uri>] [--databases <db1,db2,...>] [--clean-target] [--skip-verify] [--progress-interval <sec>]"
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
    --mongo)         MONGO_TARGET="$2";   shift 2 ;;
    --target-postgres) TARGET_POSTGRES="$2"; shift 2 ;;
    --target-db)     TARGET_DB="$2";       shift 2 ;;
    --admin-postgres) ADMIN_POSTGRES="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2";       shift 2 ;;
    --databases)     ONLY_DATABASES="$2";  shift 2 ;;
    --collections)   ONLY_COLLECTIONS="$2"; shift 2 ;;
    --stream)        STREAM=true;         shift ;;
    --max-concurrent) MAX_CONCURRENT="$2"; shift 2 ;;
    --parallel-collections) PARALLEL_COLLECTIONS="$2"; shift 2 ;;
    --insertion-workers)    INSERTION_WORKERS="$2";     shift 2 ;;
    --clean-target)  CLEAN_TARGET=true;   shift ;;
    --skip-verify)   SKIP_VERIFY=true;    shift ;;
    --progress-interval) PROGRESS_INTERVAL="$2"; shift 2 ;;
    *)               usage ;;
  esac
done

[[ -z "$SOURCE_MONGO" ]] && { echo "ERROR: --source-mongo is required" >&2; usage; }

if [[ -n "$FERRETDB" && -n "$MONGO_TARGET" ]]; then
  echo "ERROR: --ferretdb and --mongo are mutually exclusive" >&2
  usage
fi
if [[ -z "$FERRETDB" && -z "$MONGO_TARGET" ]]; then
  echo "ERROR: one of --ferretdb or --mongo is required" >&2
  usage
fi
if [[ -n "$MONGO_TARGET" ]]; then
  FERRETDB="$MONGO_TARGET"
  TARGET_IS_MONGO=true
fi

if [[ -n "$TARGET_DB" && -n "$TARGET_POSTGRES" ]]; then
  echo "ERROR: --target-db and --target-postgres are mutually exclusive" >&2
  usage
fi
if [[ "$TARGET_IS_MONGO" == "true" && ( -n "$TARGET_POSTGRES" || -n "$TARGET_DB" || -n "$ADMIN_POSTGRES" || "$CLEAN_TARGET" == "true" ) ]]; then
  echo "ERROR: --target-postgres, --target-db, --admin-postgres, and --clean-target only apply to FerretDB targets" >&2
  usage
fi
if [[ -n "$ADMIN_POSTGRES" && -z "$TARGET_POSTGRES" && -z "$TARGET_DB" ]]; then
  echo "ERROR: --admin-postgres requires --target-postgres or --target-db" >&2
  usage
fi
if [[ -n "$ONLY_COLLECTIONS" && -z "$ONLY_DATABASES" ]]; then
  echo "ERROR: --collections requires --databases with exactly one database" >&2
  usage
fi
if [[ -n "$ONLY_COLLECTIONS" ]]; then
  IFS=',' read -ra _check_dbs <<< "$ONLY_DATABASES"
  if [[ ${#_check_dbs[@]} -ne 1 ]]; then
    echo "ERROR: --collections requires exactly one database in --databases" >&2
    usage
  fi
fi

[[ -z "$MAX_CONCURRENT" ]] && { [[ "$STREAM" == "true" ]] && MAX_CONCURRENT=2 || MAX_CONCURRENT=1; }

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
  if [[ -n "$ADMIN_POSTGRES" ]]; then
    "$SCRIPT_DIR/scripts/prepare-target-db.sh" "$TARGET_POSTGRES" "$ADMIN_POSTGRES"
  else
    "$SCRIPT_DIR/scripts/prepare-target-db.sh" "$TARGET_POSTGRES"
  fi
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

# ── Clean target DocumentDB catalog if requested ─────────────────────────────
if [[ "$CLEAN_TARGET" == "true" ]]; then
  if [[ -z "$TARGET_POSTGRES" ]]; then
    echo "ERROR: --clean-target requires --target-postgres or --target-db" >&2
    exit 1
  fi
  echo "=== Cleaning stale DocumentDB catalog entries ==="
  _db_list=$(printf "'%s'," "${DATABASES[@]}" | sed 's/,$//')
  _dropped=$(psql "$TARGET_POSTGRES" -t -A -c "
    SELECT count(*) FROM documentdb_api_catalog.collections
    WHERE database_name IN (${_db_list});
  ")
  if [[ "$_dropped" -gt 0 ]]; then
    psql "$TARGET_POSTGRES" -c "
      SELECT documentdb_api.drop_collection(c.database_name, c.collection_name)
      FROM documentdb_api_catalog.collections c
      WHERE c.database_name IN (${_db_list});
    "
    echo "  Dropped $_dropped stale collection(s) from DocumentDB catalog"
  else
    echo "  No stale entries found"
  fi
  echo ""
fi

# ── Migration ─────────────────────────────────────────────────────────────────
RESULT_DIR=$(mktemp -d -t mongo-results-XXXXXX)

echo ""
echo "=== Starting migration ==="
if [[ "$STREAM" == "true" ]]; then
  echo "Mode: stream (mongodump | mongorestore, no temp disk)"
else
  DUMP_DIR=$(mktemp -d -t mongo-dump-XXXXXX)
  echo "Mode: dump+restore (temp dir: $DUMP_DIR)"
fi
# FerretDB/DocumentDB races when creating multiple collections in parallel, so the
# restore side is pinned to 1 unless the target is real MongoDB.
if [[ "$TARGET_IS_MONGO" == "true" ]]; then
  RESTORE_PARALLEL_COLLECTIONS="$PARALLEL_COLLECTIONS"
else
  RESTORE_PARALLEL_COLLECTIONS=1
fi

echo "Target: $([[ "$TARGET_IS_MONGO" == "true" ]] && echo MongoDB || echo FerretDB)"
if [[ "$STREAM" == "true" ]]; then
  # mongorestore inherits parallel-collections from the archive, so dump and
  # restore must use the same value in stream mode.
  echo "Concurrency: $MAX_CONCURRENT database(s), $RESTORE_PARALLEL_COLLECTIONS parallel collections (dump+restore coupled in stream mode), $INSERTION_WORKERS insertion workers"
else
  echo "Concurrency: $MAX_CONCURRENT database(s), $PARALLEL_COLLECTIONS dump / $RESTORE_PARALLEL_COLLECTIONS restore parallel collections, $INSERTION_WORKERS insertion workers"
fi

MIGRATION_START=$(date +%s)

# Count source documents and uncompressed bytes per database (single mongosh call)
mongosh --quiet --norc "$SOURCE_MONGO" --eval "
  const dbs = [$(printf "'%s'," "${DATABASES[@]}" | sed 's/,$//')]
  dbs.forEach(dbName => {
    const d = db.getSiblingDB(dbName);
    let docs = 0, bytes = 0;
    d.getCollectionNames().forEach(c => {
      const coll = d.getCollection(c);
      try {
        const s = coll.stats();
        docs  += (s.count || 0);
        bytes += (s.size  || 0);
      } catch (e) {
        docs += coll.estimatedDocumentCount();
      }
    });
    print(dbName + '\t' + docs + '\t' + bytes);
  });
" | while IFS=$'\t' read -r _db _count _bytes; do
  [[ -n "$_db" ]] || continue
  echo "$_count"          > "$RESULT_DIR/$_db.doc_count"
  echo "${_bytes:-0}"     > "$RESULT_DIR/$_db.source_size"
done

# ── Run migration (stream or dump+restore) ───────────────────────────────────

# Run "$@" with a backgrounded progress watcher polling the target for $db.
# Watcher is silently skipped when PROGRESS_INTERVAL <= 0 or doc count is 0.
_with_progress() {
  local db="$1"; shift
  local _docs _bytes _wpid=""

  if (( PROGRESS_INTERVAL > 0 )); then
    _docs=$(cat "$RESULT_DIR/$db.doc_count"   2>/dev/null || echo 0)
    _bytes=$(cat "$RESULT_DIR/$db.source_size" 2>/dev/null || echo 0)
    if [[ "$_docs" =~ ^[0-9]+$ ]] && (( _docs > 0 )); then
      "$SCRIPT_DIR/scripts/progress-watcher.sh" \
        "$FERRETDB" "$db" "$_docs" "$_bytes" "$PROGRESS_INTERVAL" &
      _wpid=$!
    fi
  fi

  "$@"
  local _rc=$?

  if [[ -n "$_wpid" ]]; then
    kill "$_wpid" 2>/dev/null || true
    wait "$_wpid" 2>/dev/null || true
  fi

  return $_rc
}

_migrate_one() {
  local db="$1" _s _elapsed _docs
  _docs=$(cat "$RESULT_DIR/$db.doc_count" 2>/dev/null || echo "?")

  if [[ "$STREAM" == "true" ]]; then
    echo "  → $db ($_docs docs): streaming ..."
    _s=$(date +%s)
    if _with_progress "$db" \
         "$SCRIPT_DIR/scripts/stream-database.sh" "$SOURCE_MONGO" "$FERRETDB" "$db" \
         "$RESTORE_PARALLEL_COLLECTIONS" "$INSERTION_WORKERS" "$ONLY_COLLECTIONS"; then
      _elapsed=$(( $(date +%s) - _s ))
      echo "$_elapsed" > "$RESULT_DIR/$db.migrate_time"
      echo "  ✓ $db streamed in ${_elapsed}s"
      touch "$RESULT_DIR/$db.ok"
    else
      _elapsed=$(( $(date +%s) - _s ))
      echo "$_elapsed" > "$RESULT_DIR/$db.migrate_time"
      echo "  ✗ $db stream FAILED after ${_elapsed}s" >&2
      touch "$RESULT_DIR/$db.fail"
    fi
  else
    # Dump
    echo "  → $db ($_docs docs): dumping ..."
    _s=$(date +%s)
    if ! "$SCRIPT_DIR/scripts/dump-database.sh" "$SOURCE_MONGO" "$db" "$DUMP_DIR" \
           "$PARALLEL_COLLECTIONS" "$ONLY_COLLECTIONS"; then
      _elapsed=$(( $(date +%s) - _s ))
      echo "  ✗ $db dump FAILED after ${_elapsed}s" >&2
      touch "$RESULT_DIR/$db.fail"
      return 1
    fi
    _elapsed=$(( $(date +%s) - _s ))
    echo "$_elapsed" > "$RESULT_DIR/$db.dump_time"
    _bytes=$(du -sb "$DUMP_DIR/$db" 2>/dev/null | cut -f1)
    echo "${_bytes:-0}" > "$RESULT_DIR/$db.dump_size"
    _mb=$(awk "BEGIN { printf \"%.1f\", ${_bytes:-0} / 1048576 }")
    echo "  ✓ $db dumped: ${_mb} MB in ${_elapsed}s"

    # Restore
    echo "  → $db: restoring ..."
    _s=$(date +%s)
    if _with_progress "$db" \
         "$SCRIPT_DIR/scripts/restore-database.sh" "$FERRETDB" "$db" "$DUMP_DIR" \
         "$RESTORE_PARALLEL_COLLECTIONS" "$INSERTION_WORKERS" "$ONLY_COLLECTIONS"; then
      _elapsed=$(( $(date +%s) - _s ))
      echo "$_elapsed" > "$RESULT_DIR/$db.restore_time"
      echo "  ✓ $db restored in ${_elapsed}s"
      touch "$RESULT_DIR/$db.ok"
    else
      _elapsed=$(( $(date +%s) - _s ))
      echo "$_elapsed" > "$RESULT_DIR/$db.restore_time"
      echo "  ✗ $db restore FAILED after ${_elapsed}s" >&2
      touch "$RESULT_DIR/$db.fail"
    fi
  fi
}

echo ""
echo "── Migrating ${#DATABASES[@]} database(s), max $MAX_CONCURRENT concurrent ──"
ACTIVE_PIDS=()
ACTIVE_DBS=()
_db_idx=0

while [[ $_db_idx -lt ${#DATABASES[@]} ]] || [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; do
  # Launch up to MAX_CONCURRENT
  while [[ $_db_idx -lt ${#DATABASES[@]} ]] && [[ ${#ACTIVE_PIDS[@]} -lt $MAX_CONCURRENT ]]; do
    db="${DATABASES[$_db_idx]}"
    _db_idx=$((_db_idx + 1))
    _migrate_one "$db" &
    ACTIVE_PIDS+=($!)
    ACTIVE_DBS+=("$db")
  done

  # Wait for any one to finish
  if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; then
    wait -n "${ACTIVE_PIDS[@]}" 2>/dev/null || true
    # Rebuild active list (remove finished PIDs)
    _new_pids=()
    _new_dbs=()
    for i in "${!ACTIVE_PIDS[@]}"; do
      if kill -0 "${ACTIVE_PIDS[$i]}" 2>/dev/null; then
        _new_pids+=("${ACTIVE_PIDS[$i]}")
        _new_dbs+=("${ACTIVE_DBS[$i]}")
      fi
    done
    ACTIVE_PIDS=("${_new_pids[@]+"${_new_pids[@]}"}")
    ACTIVE_DBS=("${_new_dbs[@]+"${_new_dbs[@]}"}")
  fi
done

# Wait for any stragglers
wait

MIGRATE_END=$(date +%s)
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
WALL_TIME=$(( MIGRATION_END - MIGRATION_START ))
echo ""
echo "=== Migration Statistics ==="

TOTAL_BYTES=0
TOTAL_DOCS=0

if [[ "$STREAM" == "true" ]]; then
  printf "%-32s %10s %10s\n" "Database" "Documents" "Time (s)"
  printf "%-32s %10s %10s\n" "--------------------------------" "----------" "----------"
  for db in "${DATABASES[@]}"; do
    _docs=$(cat "$RESULT_DIR/$db.doc_count" 2>/dev/null || echo 0)
    _mt=$(cat "$RESULT_DIR/$db.migrate_time" 2>/dev/null || echo -)
    printf "%-32s %10s %10s\n" "$db" "$_docs" "${_mt}"
    TOTAL_DOCS=$(( TOTAL_DOCS + _docs ))
  done
  printf "%-32s %10s %10s\n" "--------------------------------" "----------" "----------"
  printf "%-32s %10s %10s\n" "TOTAL" "$TOTAL_DOCS" "${WALL_TIME}"
else
  printf "%-32s %10s %10s %10s %12s\n" "Database" "Dump (MB)" "Documents" "Dump (s)" "Restore (s)"
  printf "%-32s %10s %10s %10s %12s\n" "--------------------------------" "----------" "----------" "----------" "------------"
  for db in "${DATABASES[@]}"; do
    _bytes=$(cat "$RESULT_DIR/$db.dump_size" 2>/dev/null || echo 0)
    _docs=$(cat "$RESULT_DIR/$db.doc_count" 2>/dev/null || echo 0)
    _dt=$(cat "$RESULT_DIR/$db.dump_time" 2>/dev/null || echo -)
    _rt=$(cat "$RESULT_DIR/$db.restore_time" 2>/dev/null || echo -)
    _mb=$(awk "BEGIN { printf \"%.1f\", $_bytes / 1048576 }")
    printf "%-32s %10s %10s %10s %12s\n" "$db" "$_mb" "$_docs" "${_dt}" "${_rt}"
    TOTAL_BYTES=$(( TOTAL_BYTES + _bytes ))
    TOTAL_DOCS=$(( TOTAL_DOCS + _docs ))
  done
  TOTAL_MB=$(awk "BEGIN { printf \"%.1f\", $TOTAL_BYTES / 1048576 }")
  printf "%-32s %10s %10s %10s %12s\n" "--------------------------------" "----------" "----------" "----------" "------------"
  printf "%-32s %10s %10s %22s\n" "TOTAL" "$TOTAL_MB" "$TOTAL_DOCS" "${WALL_TIME}s wall"
fi

echo ""
echo "  Wall time:  ${WALL_TIME}s"
if [[ $WALL_TIME -gt 0 ]]; then
  if [[ "$STREAM" == "true" ]]; then
    echo "  Throughput: $(awk "BEGIN { printf \"%.0f\", $TOTAL_DOCS / $WALL_TIME }") docs/s"
  else
    echo "  Throughput: $(awk "BEGIN { printf \"%.1f\", $TOTAL_BYTES / 1048576 / $WALL_TIME }") MB/s, $(awk "BEGIN { printf \"%.0f\", $TOTAL_DOCS / $WALL_TIME }") docs/s"
  fi
fi

if [[ "$STREAM" != "true" ]]; then
  TOTAL_DUMP_TIME=0
  TOTAL_RESTORE_TIME=0
  for db in "${DATABASES[@]}"; do
    _dt=$(cat "$RESULT_DIR/$db.dump_time" 2>/dev/null || echo 0)
    _rt=$(cat "$RESULT_DIR/$db.restore_time" 2>/dev/null || echo 0)
    [[ "$_dt" =~ ^[0-9]+$ ]] && TOTAL_DUMP_TIME=$(( TOTAL_DUMP_TIME + _dt ))
    [[ "$_rt" =~ ^[0-9]+$ ]] && TOTAL_RESTORE_TIME=$(( TOTAL_RESTORE_TIME + _rt ))
  done
  TOTAL_TASK_TIME=$(( TOTAL_DUMP_TIME + TOTAL_RESTORE_TIME ))
  OVERHEAD_TIME=$(( WALL_TIME > TOTAL_TASK_TIME ? WALL_TIME - TOTAL_TASK_TIME : 0 ))

  echo ""
  echo "=== Time Breakdown ==="
  if [[ $TOTAL_TASK_TIME -gt 0 ]]; then
    _dump_pct=$(awk "BEGIN { printf \"%.0f\", $TOTAL_DUMP_TIME * 100 / $TOTAL_TASK_TIME }")
    _restore_pct=$(awk "BEGIN { printf \"%.0f\", $TOTAL_RESTORE_TIME * 100 / $TOTAL_TASK_TIME }")
  else
    _dump_pct=0; _restore_pct=0
  fi
  printf "  %-28s %6ss  (%s%%)\n" "Reading from source (dump):" "$TOTAL_DUMP_TIME" "$_dump_pct"
  printf "  %-28s %6ss  (%s%%)\n" "Writing to target (restore):" "$TOTAL_RESTORE_TIME" "$_restore_pct"
  printf "  %-28s %6ss\n" "Overhead (verify, cleanup):" "$OVERHEAD_TIME"
  printf "  %-28s %6ss\n" "Wall time:" "$WALL_TIME"

  if [[ $TOTAL_RESTORE_TIME -gt 0 && $TOTAL_DUMP_TIME -gt 0 ]]; then
    _ratio=$(awk "BEGIN { printf \"%.1f\", $TOTAL_RESTORE_TIME / $TOTAL_DUMP_TIME }")
    echo ""
    echo "  Restore is ${_ratio}x slower than dump — the target is the bottleneck."
  fi
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
if [[ "$TARGET_IS_MONGO" == "true" ]]; then
  echo "Migration complete. Existing MongoDB clients can now connect to MongoDB at:"
else
  echo "Migration complete. Existing MongoDB clients can now connect to FerretDB at:"
fi
echo "  $FERRETDB"
