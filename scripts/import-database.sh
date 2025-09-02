#!/bin/bash

# Database Import Script for EarnLayer Migration
# This script imports the exported database into the new environment

# Set your target database connection details
TARGET_DB_URL="${DATABASE_URL:-postgresql://username:password@localhost:5432/earnlayer_nextjs_db}"
EXPORT_DIR="./database-export"

echo "🗃️  Importing EarnLayer database to new environment..."

# Check if export files exist
if [ ! -d "$EXPORT_DIR" ]; then
    echo "❌ Export directory not found. Run export-database.sh first!"
    exit 1
fi

# Create database extensions first
echo "🔧 Setting up extensions..."
psql "$TARGET_DB_URL" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
psql "$TARGET_DB_URL" -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Import the complete database
if [ -f "$EXPORT_DIR/complete.sql" ]; then
    echo "📋 Importing complete database..."
    psql "$TARGET_DB_URL" -f "$EXPORT_DIR/complete.sql"
else
    echo "⚠️  complete.sql not found, importing schema and data separately..."
    
    # Import schema first
    if [ -f "$EXPORT_DIR/schema.sql" ]; then
        echo "📋 Importing schema..."
        psql "$TARGET_DB_URL" -f "$EXPORT_DIR/schema.sql"
    fi
    
    # Then import data
    if [ -f "$EXPORT_DIR/data.sql" ]; then
        echo "📊 Importing data..."
        psql "$TARGET_DB_URL" -f "$EXPORT_DIR/data.sql"
    fi
fi

# Verify import
echo "🔍 Verifying import..."
TABLE_COUNT=$(psql "$TARGET_DB_URL" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';")
echo "📊 Imported $TABLE_COUNT tables"

# Check for vector extension
VECTOR_CHECK=$(psql "$TARGET_DB_URL" -t -c "SELECT count(*) FROM pg_extension WHERE extname = 'vector';")
if [ "$VECTOR_CHECK" -gt 0 ]; then
    echo "✅ pgvector extension is installed"
else
    echo "❌ pgvector extension not found!"
fi

echo "✅ Database import completed!"
echo "🎯 Next: Update your .env.local with the new DATABASE_URL"