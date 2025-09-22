# CRITICAL TABLES - DO NOT DROP OR MODIFY

The following tables from the old schema are CRITICAL for the system to function and must be preserved:

## 1. `embeddings` Table
**Purpose**: Stores vector embeddings for similarity search
**Critical Fields**:
- `source_table` (text): 'ads' or 'content'
- `source_id` (uuid): Reference to ads.id or content.id  
- `embedding` (vector(1536)): The actual embedding vector
- `chunk_id` (integer): 0 for primary embedding

**Why Critical**: ALL vector searches depend on this table. The new code's approach of storing embeddings as text in ads.embedding will NOT work for similarity search.

## 2. `advertisers` Table
**Purpose**: Stores advertiser accounts
**Referenced By**: ad_campaigns, creator_affiliate_codes, advertiser_payments

## 3. `creator_affiliate_codes` Table  
**Purpose**: Maps affiliate codes between creators and advertisers
**Used By**: MCP server to append affiliate codes to URLs

## 4. `ad_queue` Table
**Purpose**: Pre-computed queue of display ads for chat sessions
**Critical For**: Performance of display ad serving

## 5. `effective_cpc_rates` Table (UNLOGGED)
**Purpose**: Materialized view of CPC rates for performance
**Refreshed By**: Triggers on related tables

## Tables That Can Be Modified But Need Care

### `ads` Table
- Keep existing columns: `url`, `description`, `image_url`, `needs_description`, `estimated_epc`
- Add new columns: `target_url`, `content`, `placement`, `bid_amount`, `embedding` (text)
- Copy data from old columns to new ones, don't drop old columns

### `chat_messages` Table  
- Keep existing columns: `message`, `is_user`
- Add new columns: `content`, `role`
- Convert data appropriately

### `creators` Table
- Add new columns for auth linkage and approval
- Keep all existing data

## Foreign Key Dependencies

The old schema has many foreign key relationships that must be preserved:
- ads → ad_campaigns
- ad_campaigns → advertisers  
- ad_impressions → ads, creators
- creator_affiliate_codes → creators, advertisers
- embeddings → ads (via source_id)

## DO NOT:
1. Drop the embeddings table
2. Convert vector columns to text
3. Drop existing columns from ads, creators, or chat_messages
4. Break foreign key relationships
5. Drop advertiser-related tables

## Migration Strategy:
1. Add new columns alongside old ones
2. Copy data to new columns
3. Keep both sets of columns for compatibility
4. Use views to provide unified interface
5. Let the application gradually transition