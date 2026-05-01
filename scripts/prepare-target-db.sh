#!/usr/bin/env bash
# Ensure the target PostgreSQL database exists, has the DocumentDB extension,
# and that the application user has the documentdb_admin_role.
#
# Usage: prepare-target-db.sh <postgres-uri> [admin-postgres-uri]
#   postgres-uri        URI FerretDB will connect with (the application user)
#   admin-postgres-uri  Optional URI with superuser-equivalent privileges, used
#                       for CREATE DATABASE, CREATE EXTENSION, and GRANT
#                       documentdb_admin_role. Required when the application
#                       user is not a superuser. Defaults to <postgres-uri>.
set -euo pipefail

PG_URI="${1:?Usage: prepare-target-db.sh <postgres-uri> [admin-postgres-uri]}"
ADMIN_URI="${2:-$PG_URI}"

# postgresql://user:pass@host:port/dbname?params  →  dbname
DB_NAME=$(echo "$PG_URI" | sed -n 's|.*://[^/]*/\([^?]*\).*|\1|p')
# postgresql://user:pass@host:port/...            →  user
APP_USER=$(echo "$PG_URI" | sed -n 's|^[^:]*://\([^:@/]*\).*|\1|p')

if [[ -z "$DB_NAME" ]]; then
  echo "ERROR: Could not extract database name from URI: $PG_URI" >&2
  exit 1
fi

# Re-point ADMIN_URI at the target database (it may originally point at 'postgres' or another db)
ADMIN_DB_URI=$(echo "$ADMIN_URI" | sed "s|/[^/?]*\([?]\)|/${DB_NAME}\1|; t; s|/[^/?]*$|/${DB_NAME}|")

echo "Ensuring database '$DB_NAME' exists ..."
if psql "$PG_URI" -c '\q' 2>/dev/null; then
  echo "  Database '$DB_NAME' already exists"
else
  ADMIN_MAINT_URI=$(echo "$ADMIN_URI" | sed "s|/[^/?]*\([?]\)|/postgres\1|; t; s|/[^/?]*$|/postgres|")
  psql "$ADMIN_MAINT_URI" -c "CREATE DATABASE \"${DB_NAME}\";"
  echo "  Created database '$DB_NAME'"
fi

echo "Ensuring DocumentDB extension is installed in '$DB_NAME' ..."
psql "$ADMIN_DB_URI" -c "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
echo "  DocumentDB extension ready in '$DB_NAME'"

# Grant documentdb_admin_role when an admin URI is supplied and the app user
# differs from the admin user — covers the common FerretDB-v2 setup where the
# extension is owned by 'postgres' and FerretDB connects as a separate role.
if [[ -n "$APP_USER" && "$ADMIN_URI" != "$PG_URI" ]]; then
  echo "Granting documentdb_admin_role to '$APP_USER' ..."
  psql "$ADMIN_DB_URI" -c "GRANT documentdb_admin_role TO \"${APP_USER}\";"
  echo "  Role granted"
fi
