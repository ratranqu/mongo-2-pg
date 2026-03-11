#!/usr/bin/env bash
# Validate that the PostgreSQL database contains the expected FerretDB schemas and data.
#
# Usage: validate.sh <postgres-uri> <ferretdb-uri>
#
# Checks:
#   1. PostgreSQL has schemas for testdb1 and testdb2
#   2. FerretDB returns correct document counts per collection
#   3. Spot-check: sample document content via FerretDB
set -euo pipefail

PG_URI="${1:?Usage: validate.sh <postgres-uri> <ferretdb-uri>}"
FERRETDB_URI="${2:?Missing ferretdb-uri}"

ERRORS=0

fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

pass() {
  echo "PASS: $1"
}

# ── 1. Check PostgreSQL schemas exist ─────────────────────────────────────────
echo "=== Checking PostgreSQL schemas ==="

SCHEMAS=$(psql "$PG_URI" -t -A -c "
  SELECT schema_name FROM information_schema.schemata
  WHERE schema_name IN ('testdb1', 'testdb2')
  ORDER BY schema_name;
")

if echo "$SCHEMAS" | grep -q "testdb1"; then
  pass "Schema 'testdb1' exists in PostgreSQL"
else
  fail "Schema 'testdb1' not found in PostgreSQL"
fi

if echo "$SCHEMAS" | grep -q "testdb2"; then
  pass "Schema 'testdb2' exists in PostgreSQL"
else
  fail "Schema 'testdb2' not found in PostgreSQL"
fi

# ── 2. Check document counts via FerretDB ─────────────────────────────────────
echo ""
echo "=== Checking document counts via FerretDB ==="

check_count() {
  local db="$1" coll="$2" expected="$3"
  local actual
  actual=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
    use('$db');
    print(db.getCollection('$coll').countDocuments());
  ")
  if [[ "$actual" == "$expected" ]]; then
    pass "$db.$coll: $actual documents (expected $expected)"
  else
    fail "$db.$coll: got $actual documents, expected $expected"
  fi
}

check_count testdb1 users   3
check_count testdb1 orders  2
check_count testdb2 products   4
check_count testdb2 categories 2

# ── 3. Spot-check document content ───────────────────────────────────────────
echo ""
echo "=== Spot-checking document content ==="

# Check Alice exists in testdb1.users
ALICE=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  use('testdb1');
  const doc = db.users.findOne({ name: 'Alice' });
  if (doc && doc.email === 'alice@example.com') print('OK');
  else print('MISSING');
")
if [[ "$ALICE" == "OK" ]]; then
  pass "testdb1.users: Alice document found with correct email"
else
  fail "testdb1.users: Alice document missing or has wrong email"
fi

# Check Widget exists in testdb2.products
WIDGET=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  use('testdb2');
  const doc = db.products.findOne({ sku: 'WDG-001' });
  if (doc && doc.name === 'Widget') print('OK');
  else print('MISSING');
")
if [[ "$WIDGET" == "OK" ]]; then
  pass "testdb2.products: Widget document found with correct name"
else
  fail "testdb2.products: Widget document missing or has wrong name"
fi

# Check nested document in testdb1.orders
ORDER=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  use('testdb1');
  const doc = db.orders.findOne({ user: 'Alice' });
  if (doc && doc.items && doc.items.length === 2 && doc.total === 44.48) print('OK');
  else print('MISSING');
")
if [[ "$ORDER" == "OK" ]]; then
  pass "testdb1.orders: Alice order found with nested items and correct total"
else
  fail "testdb1.orders: Alice order missing or has wrong structure"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "VALIDATION FAILED: $ERRORS check(s) failed." >&2
  exit 1
fi

echo "VALIDATION PASSED: All checks passed."
