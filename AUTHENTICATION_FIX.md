# Authentication Domain Fix for app.earnlayerai.com

## Root Cause
The authentication failure occurs because Better Auth configuration has domain mismatches between development and production settings.

## Current Configuration Issues

### 1. Missing Production Environment Variables
Your `.env.local` has development settings, but production needs:

```bash
# Production Environment Variables (add to Railway)
BETTER_AUTH_URL="https://app.earnlayerai.com"
FRONTEND_DOMAIN="https://app.earnlayerai.com"
NEXT_PUBLIC_BETTER_AUTH_URL="https://app.earnlayerai.com"
```

### 2. Cross-Domain Cookie Configuration
Your Better Auth config in `/src/lib/auth/config.ts` is correctly set up for subdomains:

```typescript
crossSubDomainCookies: {
  enabled: true,
  domain: ".earnlayerai.com", // ✅ Correct
},
cookies: {
  session_token: {
    attributes: {
      domain: ".earnlayerai.com", // ✅ Correct
    },
  },
},
```

But the `trustedOrigins` array needs the production domain.

## Immediate Fix

### Step 1: Update Railway Environment Variables
Add these to your Railway deployment:

```bash
BETTER_AUTH_URL=https://app.earnlayerai.com
FRONTEND_DOMAIN=https://app.earnlayerai.com  
NEXT_PUBLIC_BETTER_AUTH_URL=https://app.earnlayerai.com
```

### Step 2: Verify Environment Loading
The issue is that `process.env.FRONTEND_DOMAIN` is undefined in production, so it's not being added to `trustedOrigins`.

### Step 3: Check Better Auth Handler
Make sure your Better Auth API handler is accessible at:
`https://app.earnlayerai.com/api/auth/*`

## Verification Steps

1. **Check Environment Variables in Production:**
   ```bash
   # In Railway console or deployment logs
   echo $BETTER_AUTH_URL
   echo $FRONTEND_DOMAIN
   echo $NEXT_PUBLIC_BETTER_AUTH_URL
   ```

2. **Test Auth Handler:**
   ```bash
   curl https://app.earnlayerai.com/api/auth/session
   ```

3. **Check Cookie Domain:**
   - Open browser dev tools on `app.earnlayerai.com`
   - Go to Application > Cookies
   - Verify cookies have domain `.earnlayerai.com`

## Expected Behavior After Fix

1. User logs in on `app.earnlayerai.com`
2. Better Auth sets cookies with domain `.earnlayerai.com`
3. API calls to `/api/agreement/status` include the session cookie
4. Better Auth validates the session successfully
5. Agreement endpoints return proper data instead of 401

## Additional Debug Info

If the fix doesn't work, add this debug to your agreement API endpoints:

```typescript
// In /src/app/api/agreement/status/route.ts
export async function GET(request: NextRequest) {
  console.log('🔍 Debug - Headers:', Object.fromEntries(request.headers.entries()));
  console.log('🔍 Debug - Cookies:', request.cookies.getAll());
  
  const session = await auth.api.getSession({
    headers: request.headers,
  });
  
  console.log('🔍 Debug - Session:', session);
  
  if (!session) {
    return NextResponse.json(
      { error: "Authentication required" },
      { status: 401 }
    );
  }
  
  // ... rest of your code
}
```

This will show you exactly what's happening with the session validation.