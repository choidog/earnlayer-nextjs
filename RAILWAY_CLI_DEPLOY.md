# Railway CLI Deployment

## 1. Login to Railway
```bash
railway login
```

## 2. Initialize Project
```bash
railway init
# Select "Create new project" or link to existing project
```

## 3. Add PostgreSQL Database
```bash
railway add --database postgresql
```

## 4. Set Environment Variables
```bash
# Set production environment variables
railway variables set BETTER_AUTH_SECRET="your-secret-key-min-32-chars"
railway variables set BETTER_AUTH_URL="https://your-app.railway.app"  
railway variables set OPENAI_API_KEY="your-openai-api-key"
railway variables set NODE_ENV="production"
railway variables set NEXT_PUBLIC_BETTER_AUTH_URL="https://your-app.railway.app"

# Optional OAuth variables
railway variables set GOOGLE_CLIENT_ID="your-google-client-id"
railway variables set GOOGLE_CLIENT_SECRET="your-google-client-secret"
```

## 5. Get Database URL
```bash
# Get PostgreSQL connection URL
railway variables
# Copy DATABASE_URL from the output and set it
railway variables set DATABASE_URL="postgresql://..."
```

## 6. Deploy
```bash
railway deploy
```

## 7. Get Domain
```bash
railway domain
# This will show your app URL
```

## Quick Deploy Script
```bash
#!/bin/bash
# Quick deployment script
railway login
railway init
railway add --database postgresql  
railway deploy
railway domain
```

## Useful Commands
```bash
# Check deployment status
railway status

# View logs
railway logs

# Open in browser
railway open

# List all variables
railway variables

# Connect to database
railway connect postgresql
```