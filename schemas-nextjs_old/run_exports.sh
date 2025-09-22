#!/usr/bin/env bash
set -euo pipefail

# ---------- Config ----------
PSQL_FILE="export_full_schema_logic.psql"
SCHEMA="public"

# Local DB
LOCAL_HOST="localhost"
LOCAL_PORT="5432"
LOCAL_DB="earnlayer_app"
LOCAL_USER="postgres"

# Cloud DB
CLOUD_HOST="maglev.proxy.rlwy.net"
CLOUD_PORT="54960"
CLOUD_DB="railway"
CLOUD_USER="postgres"

# Output dirs
DEV_DIR="local"    # change to "local" if you prefer
PROD_DIR="cloud"
# ----------------------------

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 not found in PATH"; exit 1; }; }
need psql
need pg_dump

mkdir -p "$DEV_DIR" "$PROD_DIR"

# Helper: atomic dump to file
dump_atomic() {
  # usage: dump_atomic OUTFILE -- pg_dump ARGS...
  local outfile="$1"; shift
  if [ "$1" != "--" ]; then echo "internal usage error"; exit 2; fi
  shift
  local tmp="${outfile}.tmp.$$"
  "$@" > "$tmp"
  mv -f "$tmp" "$outfile"
}

echo "Connecting to Local DB..."
psql -W -U "$LOCAL_USER" -h "$LOCAL_HOST" -p "$LOCAL_PORT" -d "$LOCAL_DB" \
  -v outdir="$DEV_DIR" -v schema="$SCHEMA" \
  -f "$PSQL_FILE"

echo "Dumping Local schema only to $DEV_DIR/schema.sql..."
dump_atomic "$DEV_DIR/schema.sql" -- pg_dump -W -U "$LOCAL_USER" -h "$LOCAL_HOST" -p "$LOCAL_PORT" -s "$LOCAL_DB"

echo "Dumping Local schema with data to $DEV_DIR/schema_w_data.sql..."
dump_atomic "$DEV_DIR/schema_w_data.sql" -- pg_dump -W -U "$LOCAL_USER" -h "$LOCAL_HOST" -p "$LOCAL_PORT" "$LOCAL_DB"

echo "Connecting to Cloud DB..."
psql -W -U "$CLOUD_USER" -h "$CLOUD_HOST" -p "$CLOUD_PORT" -d "$CLOUD_DB" \
  -v outdir="$PROD_DIR" -v schema="$SCHEMA" \
  -f "$PSQL_FILE"

echo "Dumping Cloud schema only to $PROD_DIR/cloud_schema.sql..."
dump_atomic "$PROD_DIR/cloud_schema.sql" -- pg_dump -W -U "$CLOUD_USER" -h "$CLOUD_HOST" -p "$CLOUD_PORT" -s "$CLOUD_DB"

echo "Dumping Cloud schema with data to $PROD_DIR/cloud_schema_w_data.sql..."
dump_atomic "$PROD_DIR/cloud_schema_w_data.sql" -- pg_dump -W -U "$CLOUD_USER" -h "$CLOUD_HOST" -p "$CLOUD_PORT" "$CLOUD_DB"

echo "All exports completed."
