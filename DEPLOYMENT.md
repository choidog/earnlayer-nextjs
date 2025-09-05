# Railway Deployment Guide

## Prerequisites

1. Railway account: https://railway.app
2. GitHub repository connected to Railway

## Environment Variables Required

Set these in Railway dashboard under Variables:

```bash
DATABASE_URL=postgresql://username:password@hostname:port/database
BETTER_AUTH_SECRET=your-secret-key-min-32-chars
BETTER_AUTH_URL=https://your-app.railway.app
OPENAI_API_KEY=your-openai-api-key
RAILWAY_PUBLIC_DOMAIN=your-app.railway.app
NODE_ENV=production
NEXT_PUBLIC_BETTER_AUTH_URL=https://your-app.railway.app
```

## Optional OAuth Variables

```bash
GOOGLE_CLIENT_ID=your-google-client-id
GOOGLE_CLIENT_SECRET=your-google-client-secret
GITHUB_CLIENT_ID=your-github-client-id
GITHUB_CLIENT_SECRET=your-github-client-secret
```

## Database Setup

1. Add PostgreSQL service in Railway
2. Copy DATABASE_URL from Railway PostgreSQL service
3. Database migrations will run automatically on deploy

## CORS Configuration

For production, update `next.config.ts` CORS origin from:
```typescript
value: "http://localhost:8080"
```
to:
```typescript
value: "https://your-frontend-domain.com"
```

## Deployment Steps

1. Push code to GitHub
2. Connect repository to Railway
3. Add PostgreSQL service
4. Set environment variables
5. Deploy automatically triggers

## Health Check

- Endpoint: `/api/health`
- Timeout: 100s
- Restart policy: ON_FAILURE (max 10 retries)

## Post-Deployment

1. Verify health endpoint: `https://your-app.railway.app/api/health`
2. Test auth endpoint: `https://your-app.railway.app/api/auth/get-session`
3. Check database migrations in PostgreSQL service logs