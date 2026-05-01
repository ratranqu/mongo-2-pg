#!/usr/bin/env bash
# Ensure the target PostgreSQL database exists, has the DocumentDB extension
# installed, and that the application user holds enough privileges on the
# extension's schemas/tables/sequences to create and operate collections.
#
# Usage: prepare-target-db.sh <postgres-uri> [admin-postgres-uri]
#   postgres-uri        URI FerretDB will connect with (the application user)
#   admin-postgres-uri  Optional URI with superuser-equivalent privileges, used
#                       for CREATE DATABASE, CREATE EXTENSION, and the explicit
#                       GRANTs on the extension schemas. Required when the
#                       application user is not a superuser. Defaults to
#                       <postgres-uri>.
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

# Grant the privileges FerretDB v2 actually needs on the DocumentDB extension.
# documentdb_admin_role exists in some builds but doesn't reliably bundle DML
# on documentdb_api_catalog.* (manifests as `permission denied for table
# collections` when createCollection runs), so issue the explicit grants
# instead. All statements are idempotent.
if [[ -n "$APP_USER" && "$ADMIN_URI" != "$PG_URI" ]]; then
  echo "Granting DocumentDB privileges to '$APP_USER' ..."
  psql "$ADMIN_DB_URI" -v ON_ERROR_STOP=1 -v "app_user=$APP_USER" <<'SQL'
GRANT USAGE ON SCHEMA documentdb_api,
                     documentdb_api_catalog,
                     documentdb_api_internal,
                     documentdb_core
  TO :"app_user";

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA documentdb_api,
                                          documentdb_api_catalog,
                                          documentdb_api_internal,
                                          documentdb_core
  TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA documentdb_api,
                                    documentdb_api_catalog,
                                    documentdb_api_internal,
                                    documentdb_core
  GRANT EXECUTE ON FUNCTIONS TO :"app_user";

GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA documentdb_api,
                          documentdb_api_catalog,
                          documentdb_api_internal,
                          documentdb_core
  TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA documentdb_api,
                                    documentdb_api_catalog,
                                    documentdb_api_internal,
                                    documentdb_core
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";

GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA documentdb_api,
                              documentdb_api_catalog,
                              documentdb_api_internal,
                              documentdb_core
  TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA documentdb_api,
                                    documentdb_api_catalog,
                                    documentdb_api_internal,
                                    documentdb_core
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";
SQL
  psql "$ADMIN_DB_URI" -v ON_ERROR_STOP=1 \
    -c "GRANT CREATE ON DATABASE \"${DB_NAME}\" TO \"${APP_USER}\";"
  echo "  Privileges granted"
fi
