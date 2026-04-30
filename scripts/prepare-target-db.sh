#!/usr/bin/env bash
# Ensure the target PostgreSQL database exists and has the DocumentDB extension.
# Usage: prepare-target-db.sh <postgres-uri>
set -euo pipefail

PG_URI="${1:?Usage: prepare-target-db.sh <postgres-uri>}"

# Extract database name from URI (postgresql://user:pass@host:port/dbname?params)
DB_NAME=$(echo "$PG_URI" | sed -n 's|.*://[^/]*/\([^?]*\).*|\1|p')

if [[ -z "$DB_NAME" ]]; then
  echo "ERROR: Could not extract database name from URI: $PG_URI" >&2
  exit 1
fi

# Build a maintenance URI pointing to the default 'postgres' database
MAINT_URI=$(echo "$PG_URI" | sed "s|/[^/?]*\([?]\)|/postgres\1|; t; s|/[^/?]*$|/postgres|")

echo "Ensuring database '$DB_NAME' exists ..."
DB_EXISTS=$(psql "$MAINT_URI" -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")
if [[ "$DB_EXISTS" != "1" ]]; then
  psql "$MAINT_URI" -c "CREATE DATABASE \"${DB_NAME}\";"
  echo "  Created database '$DB_NAME'"
else
  echo "  Database '$DB_NAME' already exists"
fi

echo "Ensuring DocumentDB extension is installed in '$DB_NAME' ..."
psql "$PG_URI" -c "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
echo "  DocumentDB extension ready in '$DB_NAME'"
