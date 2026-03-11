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
- Documents are stored as JSONB (FerretDB's default mapping)
- FerretDB runs as a long-lived Kubernetes deployment, acting as a MongoDB-compatible proxy to PostgreSQL

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
│   ├── base/                         # Kustomize base: FerretDB deployment
│   │   └── ferretdb/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── kustomization.yaml
│   └── test/                         # Kustomize overlay: full test environment
│       ├── mongodb/                  #   Source MongoDB
│       ├── postgres/                 #   PostgreSQL 18
│       └── seed/                     #   Seed job with test data
├── test/
│   ├── e2e-test.sh                   # End-to-end test (assumes k8s cluster)
│   └── validate.sh                   # Validate schemas and document content
└── .github/workflows/
    └── e2e.yaml                      # CI: kind cluster + full e2e test
```

## Usage

### 1. Deploy FerretDB

FerretDB must be running and connected to your target PostgreSQL database. The Kustomize base provides a ready-to-use deployment:

```bash
# Review and customize the PostgreSQL connection URL in
# k8s/base/ferretdb/deployment.yaml (FERRETDB_POSTGRESQL_URL env var),
# then deploy:
kubectl apply -k k8s/base/
```

The default connection URL is `postgres://ferretdb:ferretdb@postgres:5432/ferretdb`. Update it to point to your PostgreSQL instance.

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

## Limitations

This migration relies on [FerretDB 1.x](https://docs.ferretdb.io/) as the MongoDB-compatible interface to PostgreSQL. While FerretDB covers core MongoDB functionality, it is **not a complete drop-in replacement**. Applications should be tested against FerretDB before cutting over. Key limitations include:

### Unsupported features

- **Transactions and sessions**: Multi-document transactions (`startTransaction`, `commitTransaction`, `abortTransaction`) and session commands are not implemented. Applications relying on ACID transactions across multiple documents will not work.
- **Change streams**: `$changeStream` is not supported. Applications using `watch()` for real-time notifications will need an alternative (e.g., PostgreSQL `LISTEN`/`NOTIFY`).
- **Replication and sharding**: Replica set and sharding commands are not implemented. FerretDB runs as a single proxy instance; high availability must be handled at the PostgreSQL and Kubernetes level.

### Aggregation pipeline

FerretDB supports basic aggregation stages (`$match`, `$project`, `$group`, `$sort`, `$limit`, `$skip`, `$unwind`, `$count`) but **many advanced stages are missing**:

- Not supported: `$lookup` (joins), `$graphLookup`, `$facet`, `$merge`, `$out`, `$unionWith`, `$bucket`, `$bucketAuto`, `$setWindowFields`
- Most aggregation expression operators are unimplemented: only `$sum` and `$count` accumulators work in `$group`. Arithmetic (`$add`, `$multiply`), string (`$concat`, `$substr`), date (`$dateToString`, `$year`), array (`$arrayElemAt`, `$filter`), conditional (`$cond`, `$ifNull`), and type operators are not available.

### Query and update operators

- **Queries**: Core operators (`$eq`, `$gt`, `$lt`, `$in`, `$exists`, `$regex`, `$elemMatch`, etc.) are supported. Bitwise query operators and `$jsonSchema` are not.
- **Updates**: Field operators (`$set`, `$unset`, `$inc`, `$rename`, `$push`, `$pull`, `$addToSet`, `$pop`) work. Positional array operators (`$`, `$[]`, `$[<identifier>]`) have known issues. Array filters (`arrayFilters`) are not supported.
- **Collation**: The `collation` option is ignored on all commands. String sorting and comparison follow PostgreSQL's default behavior rather than MongoDB's locale-aware collation.

### Indexes

- Basic single-field and compound indexes are supported.
- **Not supported**: text indexes, geospatial indexes (`2d`, `2dsphere`), hashed indexes, wildcard indexes, and partial indexes (`partialFilterExpression`). Applications using `$text`, `$near`, `$geoWithin`, or other geo queries will not work.

### Data type caveats

- Documents are stored as JSONB in PostgreSQL, which means BSON-specific types (Decimal128, MinKey/MaxKey, regular expressions as values) may lose fidelity or behave differently.
- Collection names must be valid UTF-8 (MongoDB allows invalid UTF-8 sequences).
- Error messages may differ from MongoDB even when error codes match.

### Performance

- FerretDB translates MongoDB wire protocol to SQL at runtime. For read-heavy workloads, queries that would use a MongoDB-specific index (text, geo, hashed) will fall back to sequential scans.
- Complex aggregation pipelines that MongoDB would execute natively must be processed by FerretDB's translation layer, which may be significantly slower.
- Write-heavy workloads may see different throughput characteristics due to PostgreSQL's MVCC model vs. MongoDB's WiredTiger engine.

### Recommendation

Before migrating production workloads, use FerretDB's [pre-migration testing](https://docs.ferretdb.io/migration/premigration-testing/) mode to proxy traffic to both MongoDB and FerretDB simultaneously. This will surface any `NotImplemented` errors for operations your application uses. Alternatively, run your application's test suite against FerretDB to identify incompatibilities.
