# MongoDB to PostgreSQL Migration via FerretDB — Implementation Plan

## Overview

Migrate multiple MongoDB databases to a PostgreSQL 18 instance via FerretDB, where each
MongoDB database becomes a PostgreSQL schema. FerretDB provides MongoDB wire-protocol
compatibility so existing clients only need to change their connection string.

## Architecture

```
┌──────────────┐    mongodump     ┌────────────────┐   mongorestore   ┌──────────────┐    PostgreSQL    ┌──────────────┐
│  Source       │ ──────────────► │  /tmp/dump/     │ ───────────────► │  FerretDB    │ ──────────────► │  PostgreSQL  │
│  MongoDB      │   per database  │  (local files)  │   per database   │  (k8s pod)   │   wire proto    │  (k8s/ext)   │
└──────────────┘                  └────────────────┘                   └──────────────┘                  └──────────────┘
                                                                        ▲                                 │
                                                                        │  MongoDB protocol               │ One schema
                                                                        │  on port 27017                  │ per database
                                                                     Existing MongoDB clients             │
                                                                     (just change conn string)            ▼
                                                                                                      ┌────────────┐
                                                                                                      │ schema: db1│
                                                                                                      │ schema: db2│
                                                                                                      │ ...        │
                                                                                                      └────────────┘
```

## Repository Structure

```
mongo-2-pg/
├── migrate.sh                      # Main migration script
├── scripts/
│   ├── list-databases.sh           # List non-system DBs on source MongoDB
│   ├── dump-database.sh            # mongodump a single database
│   ├── restore-database.sh         # mongorestore a single database to FerretDB
│   └── verify-migration.sh         # Verify document counts match per DB/collection
├── k8s/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   └── ferretdb/
│   │       ├── deployment.yaml     # FerretDB Deployment (long-lived)
│   │       ├── service.yaml        # FerretDB Service (exposes port 27017)
│   │       └── kustomization.yaml
│   └── test/
│       ├── kustomization.yaml      # Test overlay (includes base + test infra)
│       ├── mongodb/
│       │   ├── deployment.yaml     # Test MongoDB instance
│       │   ├── service.yaml
│       │   └── kustomization.yaml
│       ├── postgres/
│       │   ├── deployment.yaml     # Test PostgreSQL 18 instance
│       │   ├── service.yaml
│       │   └── kustomization.yaml
│       └── seed/
│           ├── job.yaml            # K8s Job to seed 2 test databases
│           └── seed-data.js        # mongosh script: creates db1 & db2 with docs
├── test/
│   ├── e2e-test.sh                 # End-to-end test script (assumes k8s cluster)
│   └── validate.sh                 # Validates PG schemas contain expected data
├── .github/
│   └── workflows/
│       └── e2e.yaml               # GitHub Actions: spins up kind, runs test
└── README.md                       # (only if requested)
```

## Detailed Steps

### Step 1: Migration Scripts

#### `migrate.sh` (main entrypoint)
- **Inputs**: `--source-mongo <conn-string>` and `--target-postgres <conn-string>` and `--ferretdb <conn-string>` (the FerretDB MongoDB-protocol endpoint)
- **Flow**:
  1. Validate inputs (connection strings, tool availability: `mongodump`, `mongorestore`, `mongosh`)
  2. Call `list-databases.sh` to get all non-system databases from source MongoDB
  3. For each database:
     a. `dump-database.sh` — runs `mongodump --uri=<source> --db=<name> --out=/tmp/mongo-dump/`
     b. `restore-database.sh` — runs `mongorestore --uri=<ferretdb> --nsInclude=<name>.* /tmp/mongo-dump/<name>/`
  4. Call `verify-migration.sh` — for each DB/collection, compare document counts between source and FerretDB
  5. Print summary (databases migrated, document counts, any errors)

#### `scripts/list-databases.sh`
- Uses `mongosh --eval 'db.adminCommand({listDatabases:1})'` against source
- Filters out `admin`, `local`, `config`
- Outputs one database name per line

#### `scripts/dump-database.sh`
- Args: `<source-uri> <db-name> <output-dir>`
- Runs: `mongodump --uri="$source_uri" --db="$db_name" --out="$output_dir"`

#### `scripts/restore-database.sh`
- Args: `<ferretdb-uri> <db-name> <dump-dir>`
- Runs: `mongorestore --uri="$ferretdb_uri" --nsInclude="${db_name}.*" "$dump_dir/$db_name"`
- FerretDB automatically creates the corresponding PostgreSQL schema

#### `scripts/verify-migration.sh`
- Args: `<source-uri> <ferretdb-uri>`
- For each database and collection, compares `db.collection.countDocuments()` on both sides
- Exits non-zero if any mismatch

### Step 2: Kubernetes Manifests (Kustomize)

#### Base — FerretDB
- `k8s/base/ferretdb/deployment.yaml`:
  - Image: `ghcr.io/ferretdb/ferretdb:latest`
  - Env: `FERRETDB_POSTGRESQL_URL` (from ConfigMap/Secret, overridden per overlay)
  - Port: 27017
  - Readiness probe on FerretDB's debug endpoint
- `k8s/base/ferretdb/service.yaml`:
  - ClusterIP service exposing port 27017

#### Test Overlay
- `k8s/test/postgres/deployment.yaml`:
  - Image: `postgres:18`
  - Env: `POSTGRES_DB=ferretdb`, `POSTGRES_USER=ferretdb`, `POSTGRES_PASSWORD=ferretdb`
  - Port: 5432
  - Volume: emptyDir (ephemeral for tests)
- `k8s/test/mongodb/deployment.yaml`:
  - Image: `mongo:7` (compatible with FerretDB tooling)
  - Port: 27017
- `k8s/test/seed/job.yaml`:
  - Image: `mongo:7` (has `mongosh`)
  - Runs `seed-data.js` via ConfigMap mount
  - Creates 2 databases (`testdb1`, `testdb2`) with sample collections and documents

#### Seed Data (`seed-data.js`)
```javascript
// testdb1: "users" collection with 3 docs, "orders" collection with 2 docs
// testdb2: "products" collection with 4 docs, "categories" collection with 2 docs
```

### Step 3: End-to-End Test

#### `test/e2e-test.sh` (standalone, assumes k8s cluster)
1. `kubectl apply -k k8s/test/` — deploys MongoDB, PostgreSQL, FerretDB, seed job
2. Wait for all pods ready, wait for seed job completion
3. Port-forward source MongoDB (27017→localhost:27117) and FerretDB (27017→localhost:27217)
4. Run `./migrate.sh --source-mongo mongodb://localhost:27117 --ferretdb mongodb://localhost:27217 --target-postgres <pg-conn-string>`
5. Run `test/validate.sh` — connects to PostgreSQL directly, checks:
   - Schema `testdb1` exists with FerretDB tables
   - Schema `testdb2` exists with FerretDB tables
   - Document counts match expectations
   - Sample document content spot-checks via FerretDB
6. Cleanup: `kubectl delete -k k8s/test/`

#### `test/validate.sh`
- Uses `psql` to verify schemas exist in PostgreSQL
- Uses `mongosh` against FerretDB to verify document counts and sample data
- Exits non-zero on any failure

### Step 4: GitHub Actions CI

#### `.github/workflows/e2e.yaml`
```yaml
- Install kind, create cluster
- Install kubectl, mongosh, mongo-database-tools
- Run test/e2e-test.sh
- Upload logs as artifacts on failure
```

## Key Design Decisions

1. **mongodump/mongorestore over direct copy**: Most reliable way to move data between MongoDB-protocol-compatible endpoints. Handles all BSON types correctly.

2. **FerretDB as long-lived deployment**: Stays running after migration so existing MongoDB clients can connect immediately by just switching their connection string to point at the FerretDB service.

3. **One FerretDB instance, multiple schemas**: FerretDB natively maps each MongoDB database to a separate PostgreSQL schema within a single PostgreSQL database. No need for multiple FerretDB instances.

4. **Kustomize overlays**: Base contains only FerretDB (the production component). Test overlay adds MongoDB + PostgreSQL for testing. Users can create their own overlays for production with real PostgreSQL connection details.

5. **Verification as separate step**: The verify script compares source and destination independently, so it can be re-run after migration to confirm data integrity.

## Assumptions

- `mongodump`, `mongorestore`, and `mongosh` are available in the environment running `migrate.sh` (or we provide a container image)
- The Kubernetes cluster is already provisioned
- The PostgreSQL 18 instance is reachable from the FerretDB pod
- The source MongoDB is reachable from wherever `migrate.sh` runs
- FerretDB is already deployed and connected to the target PostgreSQL before migration runs
