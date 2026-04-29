#!/usr/bin/env bash
# Validate that the PostgreSQL database contains the expected FerretDB schemas and data.
#
# Usage: validate.sh <postgres-uri> <ferretdb-uri>
#
# Checks:
#   1. PostgreSQL has DocumentDB catalog entries for testdb1 and testdb2
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

# ── 1. Check PostgreSQL has DocumentDB data for our databases ────────────────
echo "=== Checking PostgreSQL (DocumentDB catalog) ==="

DB_LIST=$(psql "$PG_URI" -t -A -c "
  SELECT DISTINCT database_name FROM documentdb_api_catalog.collections
  WHERE database_name IN ('testdb1', 'testdb2')
  ORDER BY database_name;
")

if echo "$DB_LIST" | grep -q "testdb1"; then
  pass "Database 'testdb1' exists in DocumentDB catalog"
else
  fail "Database 'testdb1' not found in DocumentDB catalog"
fi

if echo "$DB_LIST" | grep -q "testdb2"; then
  pass "Database 'testdb2' exists in DocumentDB catalog"
else
  fail "Database 'testdb2' not found in DocumentDB catalog"
fi

# ── 2. Check document counts via FerretDB ─────────────────────────────────────
echo ""
echo "=== Checking document counts via FerretDB ==="

check_count() {
  local db="$1" coll="$2" expected="$3"
  local actual
  actual=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
    print(db.getSiblingDB('$db').getCollection('$coll').countDocuments());
  ")
  actual=$(echo "$actual" | tr -d '[:space:]')
  if [[ "$actual" == "$expected" ]]; then
    pass "$db.$coll: $actual documents (expected $expected)"
  else
    fail "$db.$coll: got '$actual' documents, expected $expected"
  fi
}

check_count testdb1 users    3
check_count testdb1 orders   2
check_count testdb1 matrices 2
check_count testdb2 products   4
check_count testdb2 categories 2

# ── 3. Spot-check document content ───────────────────────────────────────────
echo ""
echo "=== Spot-checking document content ==="

# Check Alice exists in testdb1.users
ALICE=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  const doc = db.getSiblingDB('testdb1').users.findOne({ name: 'Alice' });
  if (doc && doc.email === 'alice@example.com') print('OK');
  else print('MISSING');
" | tr -d '[:space:]')
if [[ "$ALICE" == "OK" ]]; then
  pass "testdb1.users: Alice document found with correct email"
else
  fail "testdb1.users: Alice document missing or has wrong email (got: '$ALICE')"
fi

# Check Widget exists in testdb2.products
WIDGET=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  const doc = db.getSiblingDB('testdb2').products.findOne({ sku: 'WDG-001' });
  if (doc && doc.name === 'Widget') print('OK');
  else print('MISSING');
" | tr -d '[:space:]')
if [[ "$WIDGET" == "OK" ]]; then
  pass "testdb2.products: Widget document found with correct name"
else
  fail "testdb2.products: Widget document missing or has wrong name (got: '$WIDGET')"
fi

# Check nested document in testdb1.orders (items with nested options, shipping.history)
ORDER=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  const doc = db.getSiblingDB('testdb1').orders.findOne({ user: 'Alice' });
  if (!doc || !doc.items || doc.items.length !== 2 || doc.total !== 44.48) { print('MISSING'); quit(); }
  const opts = doc.items[0].options;
  if (!opts || opts.length !== 2 || opts[0].values.length !== 2) { print('NO_OPTIONS'); quit(); }
  const hist = doc.shipping && doc.shipping.history;
  if (!hist || hist.length !== 3) { print('NO_HISTORY'); quit(); }
  print('OK');
" | tr -d '[:space:]')
if [[ "$ORDER" == "OK" ]]; then
  pass "testdb1.orders: Alice order with nested items.options and shipping.history"
else
  fail "testdb1.orders: Alice order structure wrong (got: '$ORDER')"
fi

# Check nested arrays in testdb1.users (addresses with coords, preferences.notifications.channels)
USER_NESTED=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  const doc = db.getSiblingDB('testdb1').users.findOne({ name: 'Alice' });
  if (!doc) { print('MISSING'); quit(); }
  if (!doc.addresses || doc.addresses.length !== 2) { print('NO_ADDR'); quit(); }
  if (!doc.addresses[0].coords || doc.addresses[0].coords.length !== 2) { print('NO_COORDS'); quit(); }
  const ch = doc.preferences && doc.preferences.notifications && doc.preferences.notifications.channels;
  if (!ch || ch.length !== 2) { print('NO_CHANNELS'); quit(); }
  print('OK');
" | tr -d '[:space:]')
if [[ "$USER_NESTED" == "OK" ]]; then
  pass "testdb1.users: Alice addresses with coords and nested preferences"
else
  fail "testdb1.users: Alice nested structure wrong (got: '$USER_NESTED')"
fi

# Check array-of-arrays in testdb1.matrices
MATRIX=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  const doc = db.getSiblingDB('testdb1').matrices.findOne({ name: 'identity-3x3' });
  if (!doc || !doc.data) { print('MISSING'); quit(); }
  if (doc.data.length !== 3 || doc.data[0].length !== 3) { print('BAD_DIMS'); quit(); }
  if (doc.data[0][0] !== 1 || doc.data[1][1] !== 1 || doc.data[2][2] !== 1) { print('BAD_VALUES'); quit(); }
  print('OK');
" | tr -d '[:space:]')
if [[ "$MATRIX" == "OK" ]]; then
  pass "testdb1.matrices: identity-3x3 with nested array-of-arrays"
else
  fail "testdb1.matrices: identity matrix wrong (got: '$MATRIX')"
fi

# Check nested arrays in testdb2.products (variants with sizes/inventory arrays)
VARIANT=$(mongosh --quiet --norc "$FERRETDB_URI" --eval "
  const doc = db.getSiblingDB('testdb2').products.findOne({ sku: 'WDG-001' });
  if (!doc || !doc.variants || doc.variants.length !== 2) { print('MISSING'); quit(); }
  if (doc.variants[0].sizes.length !== 3 || doc.variants[0].inventory.length !== 3) { print('BAD_VARIANT'); quit(); }
  print('OK');
" | tr -d '[:space:]')
if [[ "$VARIANT" == "OK" ]]; then
  pass "testdb2.products: Widget variants with nested sizes/inventory arrays"
else
  fail "testdb2.products: Widget variants wrong (got: '$VARIANT')"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "VALIDATION FAILED: $ERRORS check(s) failed." >&2
  exit 1
fi

echo "VALIDATION PASSED: All checks passed."
