# Troubleshooting

## FerretDB must be restarted after PostgreSQL changes

FerretDB caches metadata about the underlying PostgreSQL database (schemas, collections, catalog state). If you make changes directly on the PostgreSQL side — dropping tables, deleting catalog entries, modifying schemas, or restoring from a backup — FerretDB will not detect those changes automatically.

**Restart FerretDB after any direct PostgreSQL modification:**

```bash
# Kubernetes
kubectl rollout restart deployment/ferretdb -n <namespace>
kubectl wait --for=condition=ready pod -l app=ferretdb -n <namespace> --timeout=120s

# Docker Compose
docker compose restart ferretdb
```

If you skip the restart, FerretDB may return stale data, report collections that no longer exist, or fail with errors like `relation "..." does not exist (SQLSTATE 42P01)`.

## Deleting the target database to start from scratch

If a migration fails partway or you need to re-run it cleanly, you must clean up both PostgreSQL and the DocumentDB catalog. Dropping just the PostgreSQL database leaves stale catalog entries that cause subsequent migrations to fail.

### Option 1: Use `--clean-target` (recommended)

The migrate script can clean up stale catalog entries automatically:

```bash
./migrate.sh \
  --source-mongo "mongodb://..." \
  --ferretdb "mongodb://..." \
  --target-postgres "postgresql://user:pass@host:5432/dbname" \
  --clean-target
```

This drops all DocumentDB catalog entries for the databases being migrated before starting.

### Option 2: Manual cleanup via psql

Connect to the target PostgreSQL and drop catalog entries for the affected databases:

```bash
# See what's in the catalog
psql "$PG_URI" -c "
  SELECT database_name, collection_name
  FROM documentdb_api_catalog.collections
  ORDER BY database_name, collection_name;
"

# Drop specific databases from the catalog
psql "$PG_URI" -c "
  SELECT documentdb_api.drop_collection(c.database_name, c.collection_name)
  FROM documentdb_api_catalog.collections c
  WHERE c.database_name IN ('db1', 'db2');
"
```

### Option 3: Drop and recreate the entire PostgreSQL database

This is the most thorough reset — it removes everything and starts fresh:

```bash
# Connect to the postgres maintenance database (not the target database)
psql "postgresql://user:pass@host:5432/postgres"
```

```sql
-- Terminate existing connections
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'your_target_db' AND pid <> pg_backend_pid();

-- Drop and recreate
DROP DATABASE your_target_db;
CREATE DATABASE your_target_db OWNER ferretdb;
```

Then re-run the migration with `--target-postgres` to set up the DocumentDB extension:

```bash
./migrate.sh \
  --source-mongo "mongodb://..." \
  --ferretdb "mongodb://..." \
  --target-postgres "postgresql://user:pass@host:5432/your_target_db"
```

**Important:** After any of these options, restart FerretDB (see above) before running the migration.
