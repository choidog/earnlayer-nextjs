# Production Agreement API Endpoint Guide

## Overview
The frontend should hit the **production API endpoints**, not development URLs.

## ✅ **Correct Production Endpoints:**

### **Base URL:**
```javascript
const API_BASE = 'https://app.earnlayerai.com/api';
```

### **Agreement API Endpoints:**
```javascript
// Get current agreement (public endpoint)
GET https://app.earnlayerai.com/api/agreement/current

// Get user's agreement status (requires authentication)
GET https://app.earnlayerai.com/api/agreement/status

// Accept agreement (requires authentication) 
POST https://app.earnlayerai.com/api/agreement/accept

// Dismiss banner (optional)
POST https://app.earnlayerai.com/api/agreement/banner/dismiss
```

## 🛠️ **Frontend Implementation:**

### **API Configuration:**
```javascript
// ✅ Correct - Use production URLs:
const API_BASE = 'https://app.earnlayerai.com/api';

// ❌ Wrong - Don't use local development:
// const API_BASE = 'http://localhost:8000/api';
// const API_BASE = 'http://localhost:3000/api';
```

### **API Calls:**
```javascript
// Get current agreement
const getCurrentAgreement = async () => {
  const response = await fetch(`${API_BASE}/agreement/current`);
  return response.json();
};

// Get user agreement status (with authentication)
const getAgreementStatus = async () => {
  const response = await fetch(`${API_BASE}/agreement/status`, {
    credentials: 'include', // Include cookies for auth
  });
  return response.json();
};

// Accept agreement (with authentication)
const acceptAgreement = async (versionId) => {
  const response = await fetch(`${API_BASE}/agreement/accept`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify({
      versionId,
      acceptanceMethod: 'modal'
    }),
  });
  return response.json();
};
```

## 🧪 **Test Production Endpoints:**

### **Test Current Agreement (Public):**
```bash
curl https://app.earnlayerai.com/api/agreement/current
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

### **Test Agreement Status (Requires Auth):**
```bash
curl https://app.earnlayerai.com/api/agreement/status
```

**Expected Response (Without Auth):**
```json
{
  "error": "Authentication required"
}
```

**Expected Response (With Auth):**
```json
{
  "success": true,
  "data": {
    "hasAcceptedCurrent": false,
    "needsUpdate": true,
    "currentVersion": {
      "id": "ec88f8e6-fddc-4f47-94be-76cab7e87f64",
      "version": "1.0.0",
      "effectiveDate": "2025-09-12T10:04:15.483Z"
    }
  }
}
```

## 🔧 **Environment Configuration:**

### **Environment Variables:**
```bash
# Production environment
NEXT_PUBLIC_API_URL=https://app.earnlayerai.com/api
```

### **Dynamic Configuration:**
```javascript
const getApiBase = () => {
  // Always use production for agreement APIs
  return 'https://app.earnlayerai.com/api';
  
  // Or use environment variable:
  // return process.env.NEXT_PUBLIC_API_URL || 'https://app.earnlayerai.com/api';
};
```

## 📋 **Updated Frontend Hook:**

```javascript
import { useState, useEffect, useCallback } from 'react';

const API_BASE = 'https://app.earnlayerai.com/api';

export function useAgreement() {
  const [currentVersion, setCurrentVersion] = useState(null);
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  // Fetch current agreement version
  const fetchCurrentVersion = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      
      const response = await fetch(`${API_BASE}/agreement/current`);
      const data = await response.json();
      
      if (data.success) {
        setCurrentVersion(data.data);
      } else {
        throw new Error(data.error || 'Failed to load agreement');
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  // Fetch user agreement status
  const fetchStatus = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      
      const response = await fetch(`${API_BASE}/agreement/status`, {
        credentials: 'include',
      });
      
      if (response.status === 401) {
        setStatus(null);
        return;
      }
      
      const data = await response.json();
      if (data.success) {
        setStatus(data.data);
      } else {
        throw new Error(data.error || 'Failed to load status');
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  // Accept agreement
  const acceptAgreement = useCallback(async (versionId) => {
    try {
      setLoading(true);
      setError(null);

      const response = await fetch(`${API_BASE}/agreement/accept`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'include',
        body: JSON.stringify({
          versionId,
          acceptanceMethod: 'modal',
        }),
      });

      const data = await response.json();
      if (!data.success) {
        throw new Error(data.error || 'Failed to accept agreement');
      }

      await fetchStatus();
      return data;
    } catch (err) {
      setError(err.message);
      throw err;
    } finally {
      setLoading(false);
    }
  }, [fetchStatus]);

  return {
    currentVersion,
    status,
    loading,
    error,
    acceptAgreement,
    fetchCurrentVersion,
    fetchStatus,
  };
}
```

## ⚠️ **Important Notes:**

### **CORS Configuration:**
The production API should already be configured for CORS with your frontend domain.

### **Authentication:**
- Use `credentials: 'include'` for authenticated endpoints
- Ensure your auth system works with the production API
- Session cookies must be properly configured for the domain

### **Error Handling:**
- **200 + success:true** = Success
- **200 + success:false** = API error (check error message)
- **401** = Authentication required
- **500** = Server error

## 🚀 **Go-Live Steps:**

1. **Update all API calls** to use production URLs
2. **Test current agreement endpoint** - should return agreement JSON
3. **Test with authenticated user** - status endpoint should work
4. **Verify modal appears** when user hasn't accepted agreement
5. **Test acceptance flow** - should record in production database

## 🎯 **Result:**

Once the frontend hits the production endpoints:
- ✅ Agreement data will load from production database
- ✅ Authenticated users will see mandatory modal if not accepted
- ✅ Acceptances will be recorded in production with full audit trail
- ✅ System will work exactly as designed

**The key change: Use `https://app.earnlayerai.com/api` instead of `localhost` URLs** 🚀