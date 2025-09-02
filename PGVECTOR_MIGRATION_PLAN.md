# EarnLayer MCP Server - PgVector Migration Plan

## 🚨 CRITICAL ISSUES IDENTIFIED

### Issue 1: Vector Operator Error
**Error:** `operator does not exist: text <-> vector`
**Root Cause:** pgvector extension not properly configured or embedding column type mismatch

### Issue 2: Table Structure Mismatch
- **Python Original**: Uses separate `embeddings` table with `source_id`, `source_table`, `chunk_id`
- **TypeScript Current**: Uses direct `embedding` column in `ads` table

### Issue 3: Vector Query Pattern Differences
- **Python**: `(:emb)::vector AS emb` with parameter binding
- **TypeScript**: `${JSON.stringify(queryEmbedding)}::vector` with string interpolation

## 🎯 MIGRATION STRATEGY

### Phase 1: Database Schema Verification ✅ PRIORITY 1

#### 1.1 Check pgvector Extension
```sql
-- Verify pgvector is installed and enabled
SELECT * FROM pg_extension WHERE extname = 'vector';

-- If not installed, install it
CREATE EXTENSION IF NOT EXISTS vector;

-- Check vector types are available
SELECT typname FROM pg_type WHERE typname = 'vector';
```

#### 1.2 Verify Column Types
```sql
-- Check current embedding column types
SELECT table_name, column_name, data_type, udt_name 
FROM information_schema.columns 
WHERE column_name = 'embedding';

-- Should show 'vector' as udt_name, not 'text'
```

#### 1.3 Check Embeddings Table Structure
```sql
-- Verify if embeddings table exists (Python pattern)
SELECT * FROM information_schema.tables WHERE table_name = 'embeddings';

-- If exists, check its structure
\d embeddings;
```

### Phase 2: Fix Vector Query Patterns ⚠️ PRIORITY 2

#### 2.1 Update TypeScript Vector Query Pattern
**Current (Broken):**
```typescript
WITH q AS (SELECT ${JSON.stringify(queryEmbedding)}::vector AS emb)
```

**Should Be:**
```typescript
WITH q AS (SELECT $1::vector AS emb)
// With proper parameter binding instead of string interpolation
```

#### 2.2 Align Table Usage with Python Original
**Option A: Use Python Pattern (embeddings table)**
```sql
JOIN embeddings e ON e.source_id = a.id
    AND e.source_table = 'ads'
    AND e.chunk_id = 0
```

**Option B: Keep TypeScript Pattern (direct column)**
```sql
-- Ensure ads.embedding column exists and is vector type
WHERE a.embedding IS NOT NULL
```

### Phase 3: Implementation Fixes 🔧 PRIORITY 3

#### 3.1 TypeScript MCP Server Query Fixes
- [ ] Replace string interpolation with proper parameter binding
- [ ] Match Python's table join pattern or verify direct column approach
- [ ] Add proper vector type casting
- [ ] Test both `<->` (L2 distance) and `<#>` (inner product) operators

#### 3.2 Database Migration Scripts
- [ ] Create migration to ensure pgvector extension is enabled
- [ ] Verify/create embeddings table structure if following Python pattern
- [ ] Convert existing embedding columns to proper vector type if needed

#### 3.3 TypeScript Schema Updates
- [ ] Update Drizzle schema to match database reality
- [ ] Add embeddings table schema if using Python pattern
- [ ] Ensure vector types are properly defined

### Phase 4: Testing & Validation 🧪 PRIORITY 4

#### 4.1 Database-Level Vector Tests
```sql
-- Test vector operations directly
SELECT 1 - ('[1,2,3]'::vector <-> '[1,2,4]'::vector) AS similarity;

-- Test with actual ad embeddings
SELECT id, title, embedding FROM ads WHERE embedding IS NOT NULL LIMIT 1;
```

#### 4.2 API-Level Tests
- [ ] Test MCP server vector similarity queries
- [ ] Verify embedding generation and storage
- [ ] Test both hyperlink and display ad search
- [ ] Validate affiliate code functionality

#### 4.3 End-to-End MCP Tests
- [ ] Test full MCP JSON-RPC protocol
- [ ] Test vector similarity search tool
- [ ] Test display ad queue population
- [ ] Verify analytics logging

## 🔍 SPECIFIC MIGRATION TASKS

### Task 1: Database Schema Alignment
**Determine:** Python embeddings table vs TypeScript direct column approach
**Action:** Choose one pattern and implement consistently

### Task 2: Vector Type Configuration  
**Fix:** `text <-> vector` operator error
**Action:** Ensure pgvector extension and proper column types

### Task 3: Query Pattern Standardization
**Fix:** Parameter binding vs string interpolation
**Action:** Use Python's parameter binding approach in TypeScript

### Task 4: Business Settings Integration
**Verify:** TypeScript has all Python business settings functionality
**Action:** Ensure ad_types, ad_categories, similarity thresholds work

### Task 5: Affiliate Code System
**Status:** Placeholder in TypeScript, full implementation in Python  
**Action:** Complete affiliate code functionality migration

## 🚀 IMPLEMENTATION ORDER

1. **IMMEDIATE (Fix blocking error):**
   - Enable pgvector extension
   - Fix vector column types
   - Update query parameter binding

2. **SHORT TERM (Complete migration):**
   - Align table structure with Python
   - Implement missing affiliate code functionality
   - Add comprehensive error handling

3. **LONG TERM (Optimization):**
   - Performance optimization for vector queries
   - Advanced similarity algorithms
   - Monitoring and analytics improvements

## ✅ SUCCESS CRITERIA

- [ ] No `operator does not exist: text <-> vector` errors
- [ ] Vector similarity queries return results matching Python implementation
- [ ] MCP server handles all original Python functionality
- [ ] Hyperlink ads include affiliate codes when applicable
- [ ] Display ad queue population works with business settings
- [ ] Analytics logging matches Python implementation
- [ ] Health checks show database and OpenAI connectivity

## 📊 COMPARISON MATRIX

| Feature | Python Original | TypeScript Current | Status |
|---------|----------------|-------------------|---------|
| Vector queries | ✅ Working | ❌ Failing | CRITICAL |
| Embeddings table | ✅ Separate table | ⚠️ Direct column | DIFFERENT |
| Business settings | ✅ Complete | ✅ Complete | GOOD |
| Affiliate codes | ✅ Full impl | ⚠️ Placeholder | PARTIAL |
| MCP protocol | ✅ JSON-RPC | ✅ JSON-RPC | GOOD |
| Error handling | ✅ Graceful | ✅ Graceful | GOOD |

---

*Generated: 2025-09-01*  
*Next Action: Fix pgvector extension and vector query patterns*