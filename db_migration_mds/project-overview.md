# EarnLayer NextJS Project Overview

## Project Architecture

EarnLayer is a B2B monetized MCP (Model Context Protocol) server that provides context-aware advertising to AI agents and chatbots. The platform has pivoted from being a direct chatbot service to providing an MCP server that customers integrate to monetize their AI applications.

## Technology Stack

- **Frontend**: Next.js 15 with React
- **Backend**: Next.js API Routes
- **Database**: PostgreSQL 16/17 with pgvector extension
- **ORM**: Drizzle ORM
- **Authentication**: Better Auth (formerly custom JWT)
- **Vector Search**: pgvector for semantic ad matching
- **Deployment**: Railway

## Core Features Built

### 1. Authentication System
- **Google OAuth Integration**: Users authenticate via Google
- **API Key Management**: Users can generate API keys for MCP integration
- **Admin Authentication**: JWT-based admin panel access
- **User Approval System**: Creators require admin approval

### 2. MCP Server Implementation
- **Protocol Support**: Full MCP protocol implementation
- **Ad Search Tools**: Vector-based semantic search for relevant ads
- **Streaming Responses**: Real-time ad serving via SSE
- **Rate Limiting**: API key-based rate limiting

### 3. Ad Serving Platform
- **Ad Types**: text, banner, video, hyperlink, popup, thinking
- **Placement Options**: chat_inline, sidebar, content_promo, modal, overlay, header, footer
- **Contextual Matching**: Vector embeddings for semantic ad relevance
- **Default Ads**: Fallback system with global and creator-specific defaults

### 4. Creator Management
- **Creator Profiles**: User profiles with approval workflow
- **Business Settings**: Ad frequency, revenue vs relevance balance
- **Category Preferences**: Control over ad categories shown
- **Affiliate Codes**: Support for affiliate marketing integration

### 5. Analytics & Reporting
- **Dashboard Analytics**: Comprehensive metrics for creators
- **Impression Tracking**: Detailed ad impression recording
- **Click Tracking**: Click-through tracking with metadata
- **Revenue Tracking**: Real-time revenue calculations

### 6. Agreement System
- **Version Management**: Track agreement versions with hashes
- **User Acceptance**: Record user agreement acceptances
- **Banner Dismissals**: Track agreement banner interactions
- **Legal Compliance**: Ensure users accept latest agreements

### 7. Admin Panel
- **User Management**: View and manage all users
- **Creator Approval**: Approve/reject creator applications
- **Agreement Updates**: Deploy new agreement versions
- **System Monitoring**: View logs and system health

## Database Schema Overview

### Authentication Tables
- **users**: Frontend auth users (Google OAuth)
- **user**: Better Auth legacy table
- **account**: OAuth account linkage 
- **session**: User sessions
- **verification**: Email verification tokens
- **apikey**: Legacy API key table
- **api_keys**: Current API key implementation
- **api_key_usage**: API key usage tracking

### Creator & Business Tables
- **creators**: Creator profiles linked to users
- **business_settings**: Creator-specific ad settings
- **business_ad_type_preferences**: Ad type preferences
- **business_category_preferences**: Category preferences
- **creator_advertiser_blocklists**: Blocked advertisers
- **creator_affiliate_codes**: Affiliate marketing codes

### Advertising Tables
- **advertisers**: Advertiser accounts
- **ad_campaigns**: Advertising campaigns
- **ads**: Individual advertisements with embeddings
- **ad_categories**: Ad categorization
- **ad_category_relationships**: Many-to-many ad categories
- **default_ad_relationship**: Default ad configurations

### Tracking Tables
- **ad_impressions**: Ad impression records
- **ad_clicks**: Click tracking
- **chat_sessions**: Chat conversation sessions
- **chat_messages**: Individual chat messages
- **message_ads**: Ads shown in messages
- **ad_queue**: Display ad queue system

### Analytics Tables
- **api_logs**: API request logging
- **notifications**: User notifications
- **payouts**: Creator payout records

### Agreement Tables
- **agreement_versions**: Agreement version tracking
- **user_agreements**: User acceptance records
- **agreement_banner_dismissals**: Banner interaction tracking

### System Tables
- **admin_sessions**: Admin authentication sessions
- **embeddings**: Vector embeddings for content/ads
- **effective_cpc_rates**: Materialized CPC calculations

## Database Interfaces by Feature

### 1. Authentication Routes (`/api/auth/`)
- **Tables**: users, account, session, verification
- **Operations**: User creation, OAuth flow, session management

### 2. User Management (`/api/users/`, `/api/admin/users/`)
- **Tables**: users, creators, api_keys
- **Operations**: User CRUD, creator approval, profile management

### 3. API Key Management (`/api/api-keys/`)
- **Tables**: api_keys, api_key_usage
- **Operations**: Key generation, usage tracking, permissions

### 4. Ad Serving (`/api/ads/`, `/api/developer/ads/`)
- **Tables**: ads, ad_campaigns, ad_impressions, ad_clicks
- **Operations**: Ad retrieval, impression tracking, click recording

### 5. MCP Server (`/api/mcp/`)
- **Tables**: Multiple tables for ad search and context
- **Operations**: Vector search, ad matching, response streaming

### 6. Analytics (`/api/analytics/`)
- **Tables**: ad_impressions, ad_clicks, chat_sessions
- **Operations**: Aggregations, reporting, metrics calculation

### 7. Agreement System (`/api/agreement/`)
- **Tables**: agreement_versions, user_agreements
- **Operations**: Version management, acceptance tracking

### 8. Chat System (`/api/chat/`)
- **Tables**: chat_sessions, chat_messages
- **Operations**: Session management, message storage

### 9. Developer Tools (`/api/developer/`)
- **Tables**: business_settings, default_ad_relationship
- **Operations**: Settings management, default ad configuration

### 10. Admin Functions (`/api/admin/`)
- **Tables**: admin_sessions, creators, users
- **Operations**: Authentication, user management, system control

## Security Considerations

1. **API Key Authentication**: Most endpoints require valid API keys
2. **Resource Ownership**: Users can only access their own resources
3. **Admin Protection**: Admin routes use JWT authentication
4. **Missing Auth**: Some management endpoints lack proper authentication
5. **Database Access**: Direct database manipulation endpoints exposed

## Performance Optimizations

1. **Vector Indexing**: pgvector indexes for fast similarity search
2. **Materialized Views**: effective_cpc_rates for performance
3. **Connection Pooling**: Drizzle connection management
4. **Caching**: Ad queue system for repeated queries
5. **Batch Operations**: Bulk insert/update capabilities

## Integration Points

1. **MCP Protocol**: Standard MCP server for AI agents
2. **OAuth Providers**: Google authentication
3. **Payment Systems**: Advertiser payment tracking
4. **Affiliate Networks**: Affiliate code integration
5. **Analytics Services**: Comprehensive tracking APIs