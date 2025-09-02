#!/bin/bash

# Database Export Script for EarnLayer Migration
# This script exports the current database structure and data

# Set your current database connection details
SOURCE_DB_URL="${SOURCE_DATABASE_URL:-postgresql://username:password@localhost:5432/earnlayer_db}"
EXPORT_DIR="./database-export"

# Create export directory
mkdir -p "$EXPORT_DIR"

echo "🗃️  Exporting EarnLayer database..."

# Export schema only (structure)
echo "📋 Exporting schema..."
pg_dump "$SOURCE_DB_URL" \
  --schema-only \
  --no-owner \
  --no-privileges \
  --file="$EXPORT_DIR/schema.sql"

# Export data only 
echo "📊 Exporting data..."
pg_dump "$SOURCE_DB_URL" \
  --data-only \
  --no-owner \
  --no-privileges \
  --file="$EXPORT_DIR/data.sql"

# Export complete database (schema + data)
echo "💾 Exporting complete database..."
pg_dump "$SOURCE_DB_URL" \
  --no-owner \
  --no-privileges \
  --file="$EXPORT_DIR/complete.sql"

# Create a compressed backup
echo "🗜️  Creating compressed backup..."
pg_dump "$SOURCE_DB_URL" \
  --format=custom \
  --no-owner \
  --no-privileges \
  --file="$EXPORT_DIR/backup.dump"

echo "✅ Database export completed!"
echo "📁 Files created in: $EXPORT_DIR"
echo "   - schema.sql (structure only)"
echo "   - data.sql (data only)"  
echo "   - complete.sql (schema + data)"
echo "   - backup.dump (compressed format)"