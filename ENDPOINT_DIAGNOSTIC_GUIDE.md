# Agreement API Endpoint Diagnostic Guide

## The Real Issue: Wrong Endpoint URLs

You're absolutely correct - the frontend is hitting the wrong endpoints. Here's the diagnosis:

## ✅ **Working Endpoints (Local Development):**
```bash
# These work perfectly:
curl http://localhost:8000/api/agreement/current  # ✅ Returns full agreement JSON
curl http://localhost:8000/api/agreement/status   # ✅ Returns user status (with auth)
```

## ❌ **Non-Working Endpoints (What Frontend Might Be Hitting):**
```bash
# These don't work:
curl http://localhost:3000/api/agreement/current  # ❌ Port 3000 (default Next.js)
curl http://localhost:8080/api/agreement/current  # ❌ Port 8080 (production port)
curl https://app.earnlayerai.com/api/agreement/current  # ❌ Production (deployment issues)
```

## 🔍 **Root Cause Analysis:**

### **Port Mismatch Issue:**
Your Next.js dev server is running on **port 8000**, not the default port 3000.

Check your `package.json`:
```json
{
  "scripts": {
    "dev": "next dev -p 8000"  // ← Running on port 8000
  }
}
```

### **Common Frontend Mistakes:**

1. **Default Next.js Port**: Many devs assume Next.js runs on port 3000
2. **Environment Variables**: Frontend might have hardcoded URLs
3. **Proxy Configuration**: Frontend might be proxying to wrong port
4. **CORS Issues**: Frontend might be hitting different domain

## 🛠️ **Fix for Frontend Team:**

### **Option 1: Use Correct Port**
Update your frontend to hit the correct endpoints:

```javascript
// ❌ Wrong - Don't use these:
const API_BASE = 'http://localhost:3000/api';
const API_BASE = 'http://localhost:8080/api';

// ✅ Correct - Use this:
const API_BASE = 'http://localhost:8000/api';

// Your API calls:
fetch(`${API_BASE}/agreement/current`)
fetch(`${API_BASE}/agreement/status`)  
fetch(`${API_BASE}/agreement/accept`)
```

### **Option 2: Change Next.js to Port 3000**
If you prefer port 3000, update `package.json`:

```json
{
  "scripts": {
    "dev": "next dev"  // Runs on default port 3000
  }
}
```

### **Option 3: Environment Variables**
Set up proper environment variables:

```javascript
// In your frontend code:
const API_BASE = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000/api';
```

```bash
# In .env.local:
NEXT_PUBLIC_API_URL=http://localhost:8000/api
```

## 🧪 **Test the Correct Endpoints:**

### **Step 1: Verify Agreement Endpoint**
```bash
curl -s http://localhost:8000/api/agreement/current | jq .
```

**Expected Response:**
```json
{
  "success": true,
  "data": {
    "id": "ec88f8e6-fddc-4f47-94be-76cab7e87f64",
    "version": "1.0.0",
    "content": "# EarnLayer Publisher Agreement...",
    "effectiveDate": "2025-09-12T10:04:15.483Z"
  }
}
```

### **Step 2: Verify Status Endpoint (Requires Auth)**
```bash
# This will return 401 without authentication:
curl -s http://localhost:8000/api/agreement/status
# Response: {"error":"Authentication required"}
```

### **Step 3: Test in Frontend**
Open browser console and run:
```javascript
fetch('http://localhost:8000/api/agreement/current')
  .then(r => r.json())
  .then(data => console.log(data));
```

## 🚨 **Common Error Messages & Solutions:**

### **500 Internal Server Error**
- **Cause**: Database connection issues
- **Solution**: Ensure database is running and accessible

### **401 Unauthorized**  
- **Cause**: Missing authentication for protected endpoints
- **Solution**: Include credentials in requests to `/api/agreement/status` and `/api/agreement/accept`

### **404 Not Found**
- **Cause**: Wrong port or URL
- **Solution**: Use port 8000, not 3000

### **CORS Error**
- **Cause**: Frontend running on different port
- **Solution**: Use same origin or configure CORS properly

## 📋 **Quick Verification Checklist:**

- [ ] Frontend hitting `http://localhost:8000` (not 3000)
- [ ] Agreement endpoint returns JSON (not HTML)
- [ ] Status endpoint returns 401 (not 500) when not authenticated
- [ ] Authentication properly included for protected endpoints
- [ ] Environment variables set correctly
- [ ] No hardcoded URLs in frontend code

## 🔧 **Debugging Commands:**

```bash
# Check what port Next.js is actually running on:
ps aux | grep "next dev"

# Test all possible endpoints:
curl -s http://localhost:3000/api/agreement/current || echo "Port 3000 failed"
curl -s http://localhost:8000/api/agreement/current || echo "Port 8000 failed" 
curl -s http://localhost:8080/api/agreement/current || echo "Port 8080 failed"

# Check if any server is running on these ports:
lsof -i :3000
lsof -i :8000  
lsof -i :8080
```

## 🎯 **The Real Solution:**

The agreement system is working perfectly. The frontend just needs to:

1. **Hit the correct port**: `http://localhost:8000` (not 3000)
2. **Include authentication** for protected endpoints
3. **Handle the JSON responses** properly

Once the frontend uses the correct endpoints, the mandatory agreement modal will work exactly as designed!

**TL;DR: Change frontend API calls from port 3000 to port 8000** 🚀