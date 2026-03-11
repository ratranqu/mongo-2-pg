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
