#!/bin/bash
# Recreate the local test database and load the final schema.
# Settings (environment): PGHOST (default /tmp), PGPORT (54329), PGUSER (postgres), TT_DB (aditya).
set -e
cd "$(dirname "$0")/.."
export PGHOST="${PGHOST:-/tmp}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${TT_DB:-aditya}"
P="psql -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
for f in tests/db/00_supabase_shim.sql supabase/schema.sql; do
  $P -d "$DB" -f "$f" >/dev/null 2>/tmp/tt_reset_err.txt || { echo "FAILED: $f"; grep -v NOTICE /tmp/tt_reset_err.txt | head -5; exit 1; }
done
echo "database ready"
