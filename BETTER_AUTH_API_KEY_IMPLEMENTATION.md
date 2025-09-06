# Better Auth API Key Implementation Plan

**Status**: 🔴 **NOTHING IMPLEMENTED** - Complete implementation required  
**Priority**: HIGH - Frontend is expecting functional API key management  
**Timeline**: 2-3 hours implementation + testing

---

## 🎯 **OBJECTIVE**

Implement complete API key management system using Better Auth's official API key plugin to enable users to create, manage, and authenticate with API keys.

## 📋 **CURRENT STATE ANALYSIS**

### ❌ **What's Missing (Everything)**
- **Better Auth Config**: No API key plugin enabled
- **Database Schema**: No API key table exists  
- **API Routes**: All `/api/auth/api-key/*` endpoints return 404
- **Migrations**: No migration for API key table
- **Authentication**: No API key verification system

### ✅ **What's Working**
- Basic Better Auth setup with Google OAuth
- Frontend API key management UI (ready to consume backend)
- Database connection and migration system
- Centralized error handling system available

---

## 🚀 **IMPLEMENTATION PLAN**

### **Phase 1: Enable Better Auth API Key Plugin**
**Timeline**: 30 minutes

#### Task 1.1: Install API Key Plugin
```bash
# Check if plugin is available in current Better Auth version
npm list better-auth
```

#### Task 1.2: Update Better Auth Configuration
**File**: `src/lib/auth/config.ts`
```typescript
import { betterAuth } from "better-auth";
import { apiKey } from "better-auth/plugins";

export const auth = betterAuth({
  // ... existing config
  plugins: [
    apiKey({
      // Configuration options
      prefix: "earnlayer_",
      defaultExpiresIn: 30 * 24 * 60 * 60 * 1000, // 30 days default
      rateLimitEnabled: true,
      defaultRateLimit: {
        window: 60 * 1000, // 1 minute
        max: 1000 // 1000 requests per minute
      }
    })
  ]
});
```

**Verification**: 
- [ ] Plugin imported without errors
- [ ] Auth instance starts successfully
- [ ] No console errors in logs

### **Phase 2: Database Schema & Migration**
**Timeline**: 45 minutes

#### Task 2.1: Add API Key Table to Schema
**File**: `src/lib/db/schema.ts`
```typescript
export const apiKey = pgTable("api_key", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  hashedKey: text("hashed_key").notNull(),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  expiresAt: timestamp("expires_at"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at")
    .defaultNow()
    .$onUpdate(() => new Date())
    .notNull(),
  lastUsedAt: timestamp("last_used_at"),
  rateLimit: jsonb("rate_limit"), // { window: number, max: number, remaining: number, resetTime: number }
  permissions: jsonb("permissions"), // Array of permissions
  metadata: jsonb("metadata"), // Additional key metadata
  isActive: boolean("is_active").default(true).notNull(),
});

// Relations
export const apiKeyRelations = relations(apiKey, ({ one }) => ({
  user: one(user, { fields: [apiKey.userId], references: [user.id] }),
}));

// Types
export type ApiKey = typeof apiKey.$inferSelect;
export type NewApiKey = typeof apiKey.$inferInsert;
```

#### Task 2.2: Update Better Auth Adapter Schema
```typescript
const adapter = drizzleAdapter(db, {
  provider: "pg",
  schema: {
    user: user,
    account: account, 
    session: session,
    verification: verification,
    apiKey: apiKey, // Add API key table
  },
});
```

#### Task 2.3: Generate Migration
```bash
npx drizzle-kit generate
```

#### Task 2.4: Run Migration
```bash
npx drizzle-kit migrate
# Or if using npm script:
npm run db:migrate
```

**Verification**:
- [ ] Migration file created successfully
- [ ] Migration runs without errors locally
- [ ] API key table exists in database
- [ ] Foreign key relationship to user table works

### **Phase 3: Test API Routes (Auto-Generated)**
**Timeline**: 30 minutes

Better Auth should automatically provide these routes when the plugin is enabled:

#### Expected API Endpoints
- `GET /api/auth/api-key/list` - List user's API keys
- `POST /api/auth/api-key/create` - Create new API key
- `GET /api/auth/api-key/[id]` - Get specific API key
- `DELETE /api/auth/api-key/[id]` - Delete API key
- `PATCH /api/auth/api-key/[id]` - Update API key

#### Task 3.1: Test Route Availability
```bash
# Test with authenticated session cookie
curl -X GET https://api.earnlayerai.com/api/auth/api-key/list \
  -H "Cookie: __Secure-better-auth.session_token=VALID_SESSION_TOKEN" \
  -v
```

#### Task 3.2: Test API Key Creation
```bash
curl -X POST https://api.earnlayerai.com/api/auth/api-key/create \
  -H "Cookie: __Secure-better-auth.session_token=VALID_SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-key",
    "expiresIn": 30,
    "rateLimitEnabled": true,
    "rateLimitMax": 1000
  }'
```

**Verification**:
- [ ] Routes return 200/201 instead of 404
- [ ] Authentication is required (401 without session)
- [ ] API keys are created and stored in database
- [ ] Response format matches frontend expectations

### **Phase 4: Production Deployment**
**Timeline**: 15 minutes

#### Task 4.1: Deploy to Railway
```bash
git add .
git commit -m "Implement Better Auth API key management system

- Add apiKey plugin to Better Auth configuration
- Add api_key table to database schema
- Include API key table in drizzle adapter
- Enable automatic API key management routes

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>"

railway up
```

#### Task 4.2: Run Migration in Production
```bash
# Migration should run automatically during deployment
# Verify via Railway logs or manual trigger if needed
```

**Verification**:
- [ ] Deployment successful
- [ ] Migration runs in production
- [ ] Production API endpoints respond correctly

### **Phase 5: Frontend Integration Testing**
**Timeline**: 30 minutes

#### Task 5.1: Test Frontend Flows
- [ ] User can view existing API keys (empty list initially)
- [ ] User can create new API key with custom name and settings
- [ ] Created API key is displayed with proper metadata
- [ ] User can delete existing API keys
- [ ] Error handling works for invalid inputs

#### Task 5.2: API Key Authentication Testing
- [ ] Generated API keys can authenticate API requests
- [ ] Rate limiting works correctly
- [ ] Expired keys are rejected
- [ ] Invalid keys return proper error messages

**Verification**:
- [ ] No more 404 errors in frontend logs
- [ ] All CRUD operations work smoothly
- [ ] Error messages are user-friendly
- [ ] API key authentication functions properly

---

## 🔧 **TECHNICAL SPECIFICATIONS**

### **Database Schema Requirements**
```sql
-- Expected API key table structure
CREATE TABLE api_key (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  hashed_key TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  expires_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW() NOT NULL,
  last_used_at TIMESTAMP,
  rate_limit JSONB,
  permissions JSONB,
  metadata JSONB,
  is_active BOOLEAN DEFAULT true NOT NULL
);
```

### **API Response Formats**
```typescript
// List API keys response
{
  success: true,
  data: [
    {
      id: "api_key_id",
      name: "My API Key",
      userId: "user_id", 
      expiresAt: "2025-10-06T00:00:00Z",
      createdAt: "2025-09-06T00:00:00Z",
      lastUsedAt: null,
      isActive: true,
      // Note: actual key value is never returned for security
    }
  ]
}

// Create API key response
{
  success: true,
  data: {
    id: "api_key_id",
    name: "My API Key",
    key: "earnlayer_actual_api_key_value", // Only returned on creation
    expiresAt: "2025-10-06T00:00:00Z",
    createdAt: "2025-09-06T00:00:00Z"
  }
}
```

### **Error Handling**
- Use centralized error handling system
- Return proper HTTP status codes
- Include detailed error messages for debugging
- Frontend should handle common scenarios gracefully

---

## ⚠️ **POTENTIAL ISSUES & SOLUTIONS**

### **Issue 1**: Better Auth Plugin Version Compatibility
**Solution**: Check Better Auth version and API key plugin availability
```bash
npm list better-auth
# If plugin not available, may need to upgrade Better Auth
```

### **Issue 2**: Database Migration Conflicts
**Solution**: 
- Review existing migrations before generating new ones
- Test migration locally before production deployment
- Have rollback plan ready

### **Issue 3**: Authentication Context
**Solution**:
- Ensure session cookies are properly configured for cross-domain
- Test authentication with real user session tokens
- Verify CORS settings allow frontend requests

### **Issue 4**: Rate Limiting Configuration
**Solution**:
- Start with generous rate limits for testing
- Monitor actual usage patterns
- Implement gradual rate limit enforcement

---

## 📊 **SUCCESS CRITERIA**

### **Functional Requirements**
- [ ] Users can create API keys through frontend UI
- [ ] Users can view list of their existing API keys  
- [ ] Users can delete API keys they no longer need
- [ ] API keys can authenticate requests to protected endpoints
- [ ] Rate limiting prevents API abuse

### **Technical Requirements** 
- [ ] All API endpoints return proper HTTP status codes
- [ ] Database integrity maintained with foreign key constraints
- [ ] Error messages are informative and actionable
- [ ] System handles edge cases gracefully (expired keys, deleted users, etc.)

### **Security Requirements**
- [ ] API keys are properly hashed in database
- [ ] Original API key values are never logged or stored in plaintext
- [ ] Authentication is required for all API key management operations
- [ ] Rate limiting prevents brute force attacks

---

## 🚀 **NEXT STEPS AFTER COMPLETION**

1. **API Key Usage Analytics**: Track API key usage patterns
2. **Advanced Permissions**: Implement granular permission system
3. **API Key Scopes**: Allow limiting API keys to specific endpoints
4. **Webhook Integration**: API key events for external systems
5. **Admin Dashboard**: Admin interface for API key management

---

**Estimated Total Time**: 2-3 hours  
**Priority**: HIGH  
**Complexity**: Medium  
**Risk Level**: Low (using official Better Auth plugin)