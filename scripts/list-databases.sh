#!/usr/bin/env bash
# List all non-system databases on a MongoDB instance.
# Usage: list-databases.sh <mongo-uri>
set -euo pipefail

MONGO_URI="${1:?Usage: list-databases.sh <mongo-uri>}"

mongosh --quiet --norc "$MONGO_URI" --eval '
  const dbs = db.adminCommand({ listDatabases: 1 }).databases;
  const skip = new Set(["admin", "local", "config"]);
  dbs.filter(d => !skip.has(d.name)).forEach(d => print(d.name));
'
