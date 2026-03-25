#!/usr/bin/env bash
# Benchmark MongoDB vs FerretDB (PostgreSQL) query performance.
#
# Usage: benchmark.sh <source-mongo-uri> <ferretdb-uri> [--iterations N]
#
# Runs a suite of read/write operations against both endpoints and prints a
# side-by-side comparison of elapsed times.  The same data must already exist
# in both (run the migration first).
set -euo pipefail

MONGO_URI="${1:?Usage: benchmark.sh <source-mongo-uri> <ferretdb-uri> [--iterations N]}"
FERRETDB_URI="${2:?Missing ferretdb-uri}"
shift 2

ITERATIONS=100

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="$2"; shift 2 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

# Run a mongosh snippet N times and return elapsed milliseconds.
# Usage: time_query <uri> <js-snippet>
time_query() {
  local uri="$1" js="$2"
  mongosh --quiet --norc "$uri" --eval "
    const n = $ITERATIONS;
    const start = Date.now();
    for (let i = 0; i < n; i++) { $js }
    const elapsed = Date.now() - start;
    print(elapsed);
  " | tail -1 | tr -d '[:space:]'
}

RESULTS=()

run_bench() {
  local label="$1" js="$2"
  echo -n "  $label ... "
  local ms_mongo ms_ferret
  ms_mongo=$(time_query "$MONGO_URI" "$js")
  ms_ferret=$(time_query "$FERRETDB_URI" "$js")

  local avg_mongo avg_ferret ratio
  avg_mongo=$(awk "BEGIN { printf \"%.2f\", $ms_mongo / $ITERATIONS }")
  avg_ferret=$(awk "BEGIN { printf \"%.2f\", $ms_ferret / $ITERATIONS }")
  ratio=$(awk "BEGIN { printf \"%.2f\", ($ms_ferret + 0.001) / ($ms_mongo + 0.001) }")

  RESULTS+=("$label|$ms_mongo|$ms_ferret|$avg_mongo|$avg_ferret|$ratio")
  echo "done"
}

# ── Benchmarks ───────────────────────────────────────────────────────────────

echo "=== Performance Benchmark: MongoDB vs FerretDB ==="
echo "Iterations per test: $ITERATIONS"
echo ""

echo "Running benchmarks..."

# -- Reads --
run_bench "findOne by _id-like field" \
  "db.getSiblingDB('testdb1').users.findOne({ name: 'Alice' });"

run_bench "findOne nested field" \
  "db.getSiblingDB('testdb1').users.findOne({ 'preferences.theme': 'dark' });"

run_bench "find with filter (scan)" \
  "db.getSiblingDB('testdb1').users.find({ age: { \$gte: 25 } }).toArray();"

run_bench "find: array element match" \
  "db.getSiblingDB('testdb1').users.find({ tags: 'active' }).toArray();"

run_bench "find: nested array field" \
  "db.getSiblingDB('testdb2').products.find({ 'variants.color': 'red' }).toArray();"

run_bench "find: all documents (small)" \
  "db.getSiblingDB('testdb2').products.find({}).toArray();"

run_bench "countDocuments" \
  "db.getSiblingDB('testdb1').users.countDocuments();"

run_bench "aggregate: group + count" \
  "db.getSiblingDB('testdb1').orders.aggregate([{ \$group: { _id: '\$status', count: { \$sum: 1 } } }]).toArray();"

run_bench "aggregate: unwind + match" \
  "db.getSiblingDB('testdb1').orders.aggregate([{ \$unwind: '\$items' }, { \$match: { 'items.price': { \$gt: 10 } } }]).toArray();"

# -- Writes --
run_bench "insertOne + deleteOne" \
  "const r = db.getSiblingDB('testdb1').users.insertOne({ name: 'Temp', email: 'tmp@test.com', age: 99, tags: [], addresses: [], preferences: { notifications: { email: false, sms: false, channels: [] }, theme: 'light' } }); db.getSiblingDB('testdb1').users.deleteOne({ _id: r.insertedId });"

run_bench "updateOne (set field)" \
  "db.getSiblingDB('testdb1').users.updateOne({ name: 'Bob' }, { \$set: { age: 26 } });"

run_bench "updateOne (push to array)" \
  "db.getSiblingDB('testdb1').users.updateOne({ name: 'Bob' }, { \$push: { tags: 'bench' } }); db.getSiblingDB('testdb1').users.updateOne({ name: 'Bob' }, { \$pull: { tags: 'bench' } });"

# ── Report ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results (${ITERATIONS} iterations each) ==="
echo ""
printf "%-35s %10s %10s %10s %10s %8s\n" "Test" "Mongo(ms)" "Ferret(ms)" "Avg M(ms)" "Avg F(ms)" "Ratio"
printf "%-35s %10s %10s %10s %10s %8s\n" "---" "---------" "----------" "---------" "---------" "-----"

for row in "${RESULTS[@]}"; do
  IFS='|' read -r label ms_m ms_f avg_m avg_f ratio <<< "$row"
  printf "%-35s %10s %10s %10s %10s %8sx\n" "$label" "$ms_m" "$ms_f" "$avg_m" "$avg_f" "$ratio"
done

echo ""
echo "Ratio = FerretDB time / MongoDB time (1.00 = same, >1 = FerretDB slower)"
