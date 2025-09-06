# Frontend Integration Guide: Auto-Creator System

## 🎯 Overview

The backend now automatically creates creator profiles when users sign up through Better Auth. This guide shows how to integrate with the new system.

## 🔄 What Changed

### **Before:**
- Manual creator creation
- Frontend passed `creator_id` to APIs
- No link between Better Auth users and creators

### **After:**
- ✅ Automatic creator creation on user signup
- ✅ Pass `user_id` instead of `creator_id`
- ✅ Better Auth users automatically linked to creators

---

## 🚀 Frontend Integration Steps

### **1. Update Conversation Initialization**

**OLD CODE:**
```typescript
// ❌ Don't use this anymore
const response = await fetch('/api/conversations/initialize', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    creator_id: 'd64a4899-20e4-4ecd-a53e-057aceed54cf' // Hardcoded
  })
});
```

**NEW CODE:**
```typescript
import { useSession } from 'better-auth/react';

function useConversationInit() {
  const { data: session } = useSession();

  const initializeConversation = async () => {
    if (!session?.user?.id) {
      throw new Error('User not authenticated');
    }

    const response = await fetch('/api/conversations/initialize', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        user_id: session.user.id, // ✅ Use user.id from session
        visitor_uuid: null,
        context: 'chat_session',
      })
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to initialize conversation');
    }

    return await response.json();
  };

  return { initializeConversation };
}
```

### **2. Better Auth Session Hook**

Create a reusable hook for session management:

```typescript
// hooks/useAuth.ts
import { useSession } from 'better-auth/react';

export function useAuth() {
  const { data: session, isPending, error } = useSession();

  return {
    user: session?.user || null,
    isAuthenticated: !!session?.user,
    isLoading: isPending,
    error,
    userId: session?.user?.id || null,
  };
}
```

### **3. Update API Calls**

Replace all hardcoded `creator_id` usage:

```typescript
// services/earnlayerApi.ts
import { useAuth } from '@/hooks/useAuth';

export function useEarnLayerAPI() {
  const { userId, isAuthenticated } = useAuth();

  const initializeConversation = async (context?: string) => {
    if (!isAuthenticated || !userId) {
      throw new Error('Authentication required');
    }

    return fetch('/api/conversations/initialize', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        user_id: userId, // ✅ Dynamic user ID
        context,
      })
    });
  };

  const getAdQueue = async (conversationId: string) => {
    if (!isAuthenticated || !userId) {
      throw new Error('Authentication required');
    }

    return fetch(`/api/developer/ads/queue/${conversationId}?user_id=${userId}`);
  };

  return {
    initializeConversation,
    getAdQueue,
  };
}
```

### **4. Authentication Flow**

Update your authentication components:

```typescript
// components/AuthGate.tsx
import { useAuth } from '@/hooks/useAuth';
import { useRouter } from 'next/navigation';
import { useEffect } from 'react';

export function AuthGate({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!isLoading && !isAuthenticated) {
      router.push('/auth/login');
    }
  }, [isAuthenticated, isLoading, router]);

  if (isLoading) {
    return <div>Loading...</div>;
  }

  if (!isAuthenticated) {
    return <div>Redirecting to login...</div>;
  }

  return <>{children}</>;
}
```

### **5. Chat Component Updates**

Update your main chat component:

```typescript
// components/Chat.tsx
import { useState, useEffect } from 'react';
import { useAuth } from '@/hooks/useAuth';
import { useEarnLayerAPI } from '@/services/earnlayerApi';

export function Chat() {
  const { isAuthenticated, userId } = useAuth();
  const { initializeConversation } = useEarnLayerAPI();
  const [conversationId, setConversationId] = useState<string | null>(null);

  useEffect(() => {
    if (isAuthenticated && userId && !conversationId) {
      initializeConversation()
        .then(response => response.json())
        .then(data => {
          setConversationId(data.conversation_id);
          console.log('Conversation initialized:', data);
        })
        .catch(error => {
          console.error('Failed to initialize conversation:', error);
        });
    }
  }, [isAuthenticated, userId, conversationId]);

  if (!isAuthenticated) {
    return <div>Please log in to start chatting</div>;
  }

  return (
    <div>
      {conversationId ? (
        <div>Chat ready! Conversation ID: {conversationId}</div>
      ) : (
        <div>Initializing conversation...</div>
      )}
    </div>
  );
}
```

---

## 🛠️ Backend API Changes

### **Conversation Initialize Endpoint**

**Endpoint:** `POST /api/conversations/initialize`

**NEW Request Format:**
```json
{
  "user_id": "user_123abc", 
  "context": "chat_session",
  "visitor_uuid": null
}
```

**Response (unchanged):**
```json
{
  "conversation_id": "uuid",
  "creator_id": "uuid", 
  "ad_settings": {...},
  "status": "initialized",
  "created_at": "2025-09-06T..."
}
```

**Backward Compatibility:**
- Still accepts `creator_id` for legacy support
- Prefers `user_id` when both are provided

---

## 🔄 Migration Path

### **Phase 1: Update Frontend (Recommended)**
1. Deploy backend changes first
2. Update frontend to use `user_id` 
3. Test with new user signups
4. Gradually migrate existing sessions

### **Phase 2: Remove Legacy Support (Future)**
1. Phase out `creator_id` parameter
2. Require `user_id` in all requests
3. Clean up legacy code

---

## 🧪 Testing

### **Test New User Flow:**
1. Clear all cookies/localStorage
2. Sign up with new account
3. Verify creator is auto-created in database:
   ```sql
   SELECT * FROM creators WHERE user_id = 'new_user_id';
   ```
4. Initialize conversation and verify it works

### **Test Existing Users:**
1. Login with existing account  
2. Check if creator exists for user
3. If no creator exists, they'll get an error (expected)
4. Run migration script to link existing data

---

## 🚨 Important Notes

### **Authentication Required:**
- All chat functionality now requires authentication
- Users must be logged in before initializing conversations
- Handle unauthenticated states gracefully

### **Creator Auto-Creation:**
- Happens automatically on signup (no frontend action needed)
- Uses Better Auth user data (email, name)
- Generates unique creator names automatically

### **Error Handling:**
- "Creator profile not found" = user needs creator profile
- "No creators available" = database issue  
- Handle both cases in frontend

---

## 📋 Checklist

- [ ] Update conversation initialization to use `user_id`
- [ ] Replace hardcoded `creator_id` values
- [ ] Add authentication checks
- [ ] Update error handling
- [ ] Test new user signup flow
- [ ] Test existing user login flow
- [ ] Deploy and monitor

---

## 🆘 Troubleshooting

### **"Creator profile not found" Error:**
- User authenticated but no creator profile exists
- Run migration script to create creator profiles
- Check Better Auth hooks are working

### **"No creators available" Error:**
- Database has no creators at all
- Seed database with initial creators
- Check database connectivity

### **Authentication Issues:**
- Verify Better Auth session is working
- Check cookie settings and domains
- Ensure CORS is configured properly

---

This integration maintains backward compatibility while providing a smooth path to the new auto-creator system.