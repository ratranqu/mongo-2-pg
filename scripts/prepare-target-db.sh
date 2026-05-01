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

# Split a postgres URI into its parts using bash parameter expansion.
# Sets the named globals (passed by reference) to: scheme, authority, path, query.
# Authority is everything between '://' and the next '/' or '?', i.e. user:pass@host:port.
# Path is the dbname (no leading '/'); query keeps its leading '?' if present.
_split_pg_uri() {
  local uri="$1" __scheme=$2 __auth=$3 __path=$4 __query=$5
  local no_query="${uri%%\?*}"
  local query=""
  [[ "$uri" == *\?* ]] && query="?${uri#*\?}"

  local scheme="${no_query%%://*}"
  local rest="${no_query#*://}"
  local authority="${rest%%/*}"
  local path=""
  [[ "$rest" == */* ]] && path="${rest#*/}"

  printf -v "$__scheme" '%s' "$scheme"
  printf -v "$__auth"   '%s' "$authority"
  printf -v "$__path"   '%s' "$path"
  printf -v "$__query"  '%s' "$query"
}

_user_from_authority() {
  local auth="$1"
  if [[ "$auth" == *@* ]]; then
    local userinfo="${auth%@*}"
    echo "${userinfo%%:*}"
  fi
}

_split_pg_uri "$PG_URI"    PG_SCHEME    PG_AUTH    PG_PATH    PG_QUERY
_split_pg_uri "$ADMIN_URI" ADMIN_SCHEME ADMIN_AUTH ADMIN_PATH ADMIN_QUERY

DB_NAME="$PG_PATH"
APP_USER=$(_user_from_authority "$PG_AUTH")

if [[ -z "$DB_NAME" ]]; then
  echo "ERROR: Could not extract database name from URI: $PG_URI" >&2
  exit 1
fi

# Build admin URIs that always have a clean /dbname?query path, regardless of
# what was on the original ADMIN_URI (which often has no path, e.g. when it
# points at the maintenance 'postgres' database via just user:pass@host:port).
ADMIN_BASE="${ADMIN_SCHEME}://${ADMIN_AUTH}"
ADMIN_MAINT_URI="${ADMIN_BASE}/postgres${ADMIN_QUERY}"
ADMIN_DB_URI="${ADMIN_BASE}/${DB_NAME}${ADMIN_QUERY}"

echo "Ensuring database '$DB_NAME' exists ..."
if psql "$PG_URI" -c '\q' 2>/dev/null; then
  echo "  Database '$DB_NAME' already exists"
else
  psql "$ADMIN_MAINT_URI" -c "CREATE DATABASE \"${DB_NAME}\";"
  echo "  Created database '$DB_NAME'"
fi

echo "Ensuring DocumentDB extension is installed in '$DB_NAME' ..."
psql "$ADMIN_DB_URI" -c "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
echo "  DocumentDB extension ready in '$DB_NAME'"

# Grant the privileges FerretDB v2 actually needs on the DocumentDB extension.
# documentdb_admin_role exists in some builds but doesn't reliably bundle DML
# on documentdb_api_catalog.* (manifests as `permission denied for table
# collections` when createCollection runs), and the set of schemas the
# extension creates varies by version (api/api_catalog/api_internal/core/data,
# plus possibly more), so iterate over every documentdb_* schema dynamically
# and grant the full set on each. All statements are idempotent.
if [[ -n "$APP_USER" && "$ADMIN_URI" != "$PG_URI" ]]; then
  echo "Granting DocumentDB privileges to '$APP_USER' ..."
  # psql's :'var' substitution does NOT happen inside dollar-quoted blocks
  # ($$ ... $$), so we generate per-schema GRANT statements with format()
  # at the top level and feed them to \gexec. format(%I) handles identifier
  # quoting for both the schema name and the (possibly hyphenated) role.
  psql "$ADMIN_DB_URI" -v ON_ERROR_STOP=1 -v "app_user=$APP_USER" <<'SQL'
WITH s(nspname) AS (
  SELECT nspname FROM pg_namespace WHERE nspname LIKE 'documentdb%'
)
SELECT format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', nspname, :'app_user') FROM s
UNION ALL SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', nspname, :'app_user') FROM s
UNION ALL SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', nspname, :'app_user') FROM s
UNION ALL SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', nspname, :'app_user') FROM s
UNION ALL SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I', nspname, :'app_user') FROM s
UNION ALL SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', nspname, :'app_user') FROM s
UNION ALL SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO %I', nspname, :'app_user') FROM s
\gexec
SQL
  psql "$ADMIN_DB_URI" -v ON_ERROR_STOP=1 \
    -c "GRANT CREATE ON DATABASE \"${DB_NAME}\" TO \"${APP_USER}\";"
  echo "  Privileges granted"
fi
