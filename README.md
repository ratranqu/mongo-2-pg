# mongo-2-pg

Migrate MongoDB databases to PostgreSQL via [FerretDB](https://www.ferretdb.io/). Each MongoDB database becomes a PostgreSQL schema, and FerretDB provides MongoDB wire-protocol compatibility so existing clients only need to change their connection string.

## Architecture

```
Source MongoDB ──mongodump──► local dump ──mongorestore──► FerretDB ──► PostgreSQL
                                                             ▲
                                                             │
                                                      Existing clients
                                                      (MongoDB protocol)
```

- Each MongoDB database maps to a PostgreSQL schema
- Documents are stored as BSON in PostgreSQL via the [DocumentDB extension](https://github.com/FerretDB/documentdb)
- FerretDB 2.x runs as a long-lived Kubernetes deployment, acting as a MongoDB-compatible proxy to PostgreSQL

## Prerequisites

- `mongosh`, `mongodump`, `mongorestore` (from [MongoDB Database Tools](https://www.mongodb.com/docs/database-tools/))
- `psql` (PostgreSQL client, only needed for validation)
- `kubectl` with access to a Kubernetes cluster (for FerretDB deployment and tests)
- A running FerretDB instance connected to the target PostgreSQL database

## Repository Structure

```
mongo-2-pg/
├── migrate.sh                        # Main migration script
├── scripts/
│   ├── list-databases.sh             # List non-system databases on source
│   ├── dump-database.sh              # Dump a single database
│   ├── restore-database.sh           # Restore a single database to FerretDB
│   └── verify-migration.sh           # Verify document counts match
├── k8s/
│   ├── base/
│   │   ├── ferretdb/                 #   FerretDB deployment (reads Secret)
│   │   └── postgres/                 #   Bundled PostgreSQL + default Secret
│   └── test/                         # Kustomize overlay: full test environment
│       ├── mongodb/                  #   Source MongoDB
│       └── seed/                     #   Seed job with test data
├── test/
│   ├── e2e-test.sh                   # End-to-end test (assumes k8s cluster)
│   └── validate.sh                   # Validate schemas and document content
└── .github/workflows/
    └── e2e.yaml                      # CI: kind cluster + full e2e test
```

## Usage

### 1. Deploy FerretDB

FerretDB must be running and connected to your target PostgreSQL database. The Kustomize base deploys FerretDB only — it reads PostgreSQL connection details from a Kubernetes Secret named `ferretdb-postgres`.

**Option A: Bundled PostgreSQL** (quick start)

Deploy FerretDB together with a bundled PostgreSQL instance and default credentials:

```bash
kubectl apply -k k8s/base/
kubectl apply -k k8s/base/postgres/
```

This creates a PostgreSQL deployment (with the [DocumentDB extension](#postgresql-and-the-documentdb-extension) pre-installed) using default credentials (`ferretdb:ferretdb`) and the matching Secret.

**Option B: External PostgreSQL** (production)

If you already have a PostgreSQL instance with the DocumentDB extension installed (see [below](#postgresql-and-the-documentdb-extension)), create the Secret with your own connection details:

```bash
kubectl create secret generic ferretdb-postgres \
  --from-literal=POSTGRES_HOST=my-postgres.example.com \
  --from-literal=POSTGRES_PORT=5432 \
  --from-literal=POSTGRES_DB=ferretdb \
  --from-literal=POSTGRES_USER=myuser \
  --from-literal=POSTGRES_PASSWORD=mypassword

kubectl apply -k k8s/base/
```

The Secret must contain these keys: `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`. FerretDB constructs its connection URL from these values.

### 2. Run the Migration

```bash
./migrate.sh \
  --source-mongo "mongodb://source-host:27017" \
  --ferretdb "mongodb://ferretdb-host:27017"
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--source-mongo <uri>` | Yes | Connection string for the source MongoDB server |
| `--ferretdb <uri>` | Yes | Connection string for the FerretDB instance |
| `--target-postgres <uri>` | No | PostgreSQL connection string (informational) |
| `--skip-verify` | No | Skip post-migration document count verification |

The script will:
1. Discover all non-system databases on the source (excludes `admin`, `local`, `config`)
2. Dump each database with `mongodump`
3. Restore each into FerretDB with `mongorestore`
4. Verify document counts match between source and target
5. Print a summary

### 3. Point Clients to FerretDB

After migration, existing MongoDB clients connect to FerretDB instead of the original MongoDB:

```
# Before
mongodb://old-mongo-host:27017

# After
mongodb://ferretdb-host:27017
```

No application code changes are needed beyond the connection string.

## Individual Scripts

The migration is composed of modular scripts that can be used independently:

```bash
# List databases on a MongoDB server
./scripts/list-databases.sh "mongodb://host:27017"

# Dump a single database
./scripts/dump-database.sh "mongodb://host:27017" mydb /tmp/dump

# Restore a single database to FerretDB
./scripts/restore-database.sh "mongodb://ferretdb:27017" mydb /tmp/dump

# Verify document counts match between source and target
./scripts/verify-migration.sh "mongodb://source:27017" "mongodb://ferretdb:27017"
# Or verify specific databases:
./scripts/verify-migration.sh "mongodb://source:27017" "mongodb://ferretdb:27017" db1 db2
```

## Testing

### End-to-end Test

The e2e test deploys a complete environment in Kubernetes (source MongoDB with 2 seeded databases, PostgreSQL 18, and FerretDB), runs the migration, and validates the result.

```bash
# Requires a Kubernetes cluster (e.g., kind, minikube, or a real cluster)
./test/e2e-test.sh

# Keep resources after test for debugging:
./test/e2e-test.sh --no-cleanup
```

The test:
1. Creates a `mongo2pg-test` namespace
2. Deploys source MongoDB, PostgreSQL, and FerretDB
3. Seeds two databases (`testdb1` with users + orders, `testdb2` with products + categories)
4. Runs the full migration
5. Validates that PostgreSQL contains the correct schemas and data
6. Cleans up

### CI

The GitHub Actions workflow (`.github/workflows/e2e.yaml`) runs the full e2e test on every push using a [kind](https://kind.sigs.k8s.io/) cluster.

### Standalone Validation

After any migration, you can validate the PostgreSQL state independently:

```bash
./test/validate.sh \
  "postgresql://ferretdb:ferretdb@localhost:5432/ferretdb" \
  "mongodb://ferretdb-host:27017"
```

This checks that PostgreSQL schemas exist and document counts and content match expectations.

## PostgreSQL and the DocumentDB Extension

FerretDB 2.x requires the [DocumentDB PostgreSQL extension](https://github.com/FerretDB/documentdb) to be installed on the target PostgreSQL server. This extension provides native BSON storage and query execution inside PostgreSQL, replacing the JSONB-based approach used in FerretDB 1.x. This enables significantly better performance (up to 20x throughput improvement) and broader MongoDB compatibility — including support for nested arrays, more aggregation stages, and geospatial queries.

### Using the pre-built Docker image (recommended)

The bundled PostgreSQL deployment (`k8s/base/postgres/`) uses the pre-built image with the extension already installed:

```
ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0
```

No additional setup is needed — the extension is loaded automatically via `shared_preload_libraries`.

### Installing on a self-managed PostgreSQL

If you bring your own PostgreSQL instance, you must install the DocumentDB extension manually. PostgreSQL 17 is recommended (PostgreSQL 15 is also supported).

**Debian/Ubuntu:**

1. Download the `.deb` package from [DocumentDB releases](https://github.com/FerretDB/documentdb/releases)

2. Install the package and its dependencies (`pg_cron`, `rum`):
   ```bash
   sudo dpkg -i documentdb-*.deb
   ```

3. Update `postgresql.conf`:
   ```
   shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'
   cron.database_name = 'postgres'
   ```

4. Restart PostgreSQL:
   ```bash
   sudo systemctl restart postgresql
   ```

5. Create the extension in your target database:
   ```bash
   psql -U postgres -d ferretdb -c 'CREATE EXTENSION IF NOT EXISTS pg_documentdb CASCADE;'
   ```

For RPM-based distributions, equivalent packages are available on the same releases page.

**Important**: DocumentDB must be installed on a clean PostgreSQL instance. There is no in-place upgrade path from FerretDB 1.x's JSONB storage — data must be migrated via `mongodump`/`mongorestore`.

## Limitations

This migration relies on [FerretDB 2.x](https://docs.ferretdb.io/) (v2.7.0) with the DocumentDB PostgreSQL extension as the MongoDB-compatible interface to PostgreSQL. While FerretDB 2.x covers most MongoDB CRUD and aggregation functionality, it is **not a complete drop-in replacement**. Applications should be tested against FerretDB before cutting over. Key limitations include:

### Unsupported features

- **Transactions and sessions**: Multi-document transactions (`startSession`, `startTransaction`, `commitTransaction`, `abortTransaction`) and session commands are not implemented. ACID guarantees exist at the PostgreSQL level but are not exposed through the MongoDB wire protocol transaction API.
- **Change streams**: `$changeStream` is not supported. Applications using `watch()` for real-time notifications will need an alternative (e.g., PostgreSQL `LISTEN`/`NOTIFY` or WAL-based CDC tools like Debezium).
- **Replication and sharding**: Replica set commands (`rs.status()`, `rs.initiate()`) and sharding commands (`sh.shardCollection()`) are not implemented. FerretDB runs as a single proxy instance; high availability and replication must be handled at the PostgreSQL level (e.g., streaming replication). MongoDB driver automatic failover will not work.
- **Server-side JavaScript**: `$where` expressions and `$function`/`$accumulator` operators are not supported.

### Aggregation pipeline

FerretDB 2.x with DocumentDB supports significantly more aggregation stages and expression operators than 1.x. Most common stages (`$match`, `$project`, `$group`, `$sort`, `$limit`, `$skip`, `$unwind`, `$count`, `$set`/`$addFields`, `$unset`, `$lookup`, `$replaceRoot`/`$replaceWith`, `$sample`, `$sortByCount`) are now supported.

Some advanced stages remain unsupported — check the [FerretDB supported commands reference](https://docs.ferretdb.io/reference/supported-commands/) for the current list.

### Query and update operators

- **Queries**: Core operators (`$eq`, `$gt`, `$lt`, `$in`, `$exists`, `$regex`, `$elemMatch`, `$expr`, etc.) are supported. Bitwise query operators and `$where` are not supported.
- **Updates**: Field operators (`$set`, `$unset`, `$inc`, `$rename`, `$push`, `$pull`, `$addToSet`, `$pop`) and positional array operators (`$`, `$[]`, `$[<identifier>]`) work. Check the docs for edge cases with `arrayFilters`.
- **Collation**: Collation support was added in FerretDB 2.x, but may not cover all MongoDB collation options.

### Indexes

- Supported: single-field, compound, unique, TTL, partial (`partialFilterExpression`), `2dsphere` geospatial, hashed, and vector (HNSW/IVF) indexes.
- **Not supported**: `2d` (legacy) geospatial indexes and wildcard indexes (`$**`).
- Indexes are backed by the DocumentDB extension's internal storage. Performance characteristics may differ from MongoDB's B-tree indexes; benchmark your specific query patterns.

### Data type caveats

- FerretDB 2.x with DocumentDB stores documents using native BSON encoding in PostgreSQL, providing much better type fidelity than the 1.x JSONB/PJSON approach. Nested arrays, Decimal128, Binary, MinKey/MaxKey, and other BSON types are fully supported.
- Collection names must be valid UTF-8 (MongoDB allows invalid UTF-8 sequences).
- Error messages may differ from MongoDB even when error codes match.

### Performance

- FerretDB 2.x with DocumentDB executes queries directly inside PostgreSQL rather than fetching data into a proxy layer. This provides up to 20x throughput improvement over FerretDB 1.x.
- **Write throughput**: Different characteristics due to PostgreSQL's MVCC model vs. MongoDB's WiredTiger engine.

### Recommendation

Before migrating production workloads, run your application's full test suite against FerretDB to identify any incompatibilities. FerretDB exposes metrics with `NotImplemented` and `CommandNotFound` result statuses for monitoring unsupported operations.
