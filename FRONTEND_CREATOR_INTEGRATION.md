# Frontend Creator Profile Integration Guide

## Overview

After successful authentication, users need creator profiles to use the chat system. This guide implements automatic creator profile creation for authenticated users.

## Backend Endpoints Available

### 1. Check Creator Profile Status
```typescript
GET /api/creator/profile
```
**Purpose**: Check if authenticated user has a creator profile  
**Authentication**: Requires Better Auth session cookie  
**Response**:
```typescript
// Has creator profile
{
  hasCreatorProfile: true,
  creatorProfile: {
    id: "uuid",
    name: "Creator Name",
    email: "user@example.com",
    userId: "better-auth-user-id"
  }
}

// No creator profile
{
  hasCreatorProfile: false,
  userId: "better-auth-user-id",
  userEmail: "user@example.com", 
  userName: "User Name"
}
```

### 2. Create Creator Profile
```typescript
POST /api/creator/profile
```
**Purpose**: Create creator profile for authenticated user  
**Authentication**: Requires Better Auth session cookie  
**Response**:
```typescript
{
  success: true,
  creatorProfile: {
    id: "uuid",
    name: "Generated Creator Name",
    email: "user@example.com",
    userId: "better-auth-user-id"
  },
  message: "Creator profile created successfully"
}
```

## Implementation Steps

### Step 1: Create Creator Profile Service

Create `src/services/creatorProfileService.ts`:
```typescript
export class CreatorProfileService {
  private baseUrl: string;

  constructor(baseUrl: string = process.env.NEXT_PUBLIC_BETTER_AUTH_URL || '') {
    this.baseUrl = baseUrl;
  }

  async checkCreatorProfile(): Promise<CreatorProfileResponse> {
    const response = await fetch(`${this.baseUrl}/api/creator/profile`, {
      method: 'GET',
      credentials: 'include', // Include session cookies
      headers: {
        'Content-Type': 'application/json',
      },
    });

    if (!response.ok) {
      throw new Error(`Failed to check creator profile: ${response.status}`);
    }

    return response.json();
  }

  async createCreatorProfile(): Promise<CreateCreatorProfileResponse> {
    const response = await fetch(`${this.baseUrl}/api/creator/profile`, {
      method: 'POST',
      credentials: 'include', // Include session cookies
      headers: {
        'Content-Type': 'application/json',
      },
    });

    if (!response.ok) {
      throw new Error(`Failed to create creator profile: ${response.status}`);
    }

    return response.json();
  }

  async ensureCreatorProfile(): Promise<CreatorProfile> {
    const checkResult = await this.checkCreatorProfile();
    
    if (checkResult.hasCreatorProfile) {
      return checkResult.creatorProfile;
    }

    // Create creator profile if it doesn't exist
    const createResult = await this.createCreatorProfile();
    return createResult.creatorProfile;
  }
}

// Types
interface CreatorProfile {
  id: string;
  name: string;
  email: string;
  userId: string;
}

interface CreatorProfileResponse {
  hasCreatorProfile: boolean;
  creatorProfile?: CreatorProfile;
  userId?: string;
  userEmail?: string;
  userName?: string;
}

interface CreateCreatorProfileResponse {
  success: boolean;
  creatorProfile: CreatorProfile;
  message: string;
}
```

### Step 2: Create Creator Profile Hook

Create `src/hooks/useCreatorProfile.ts`:
```typescript
import { useState, useEffect } from 'react';
import { CreatorProfileService } from '@/services/creatorProfileService';

export function useCreatorProfile() {
  const [creatorProfile, setCreatorProfile] = useState<CreatorProfile | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const creatorService = new CreatorProfileService();

  useEffect(() => {
    ensureCreatorProfile();
  }, []);

  const ensureCreatorProfile = async () => {
    try {
      setIsLoading(true);
      setError(null);
      
      const profile = await creatorService.ensureCreatorProfile();
      setCreatorProfile(profile);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load creator profile');
    } finally {
      setIsLoading(false);
    }
  };

  return {
    creatorProfile,
    isLoading,
    error,
    refetch: ensureCreatorProfile,
  };
}
```

### Step 3: Update Dashboard Component

Update your dashboard page/component:
```typescript
import { useCreatorProfile } from '@/hooks/useCreatorProfile';

export default function Dashboard() {
  const { creatorProfile, isLoading, error } = useCreatorProfile();

  if (isLoading) {
    return <div>Setting up your profile...</div>;
  }

  if (error) {
    return <div>Error: {error}</div>;
  }

  if (!creatorProfile) {
    return <div>Failed to create profile. Please try refreshing.</div>;
  }

  // Dashboard is ready - user has creator profile
  return (
    <div>
      <h1>Welcome, {creatorProfile.name}!</h1>
      {/* Rest of dashboard */}
    </div>
  );
}
```

### Step 4: Update Chat Initialization

Update your chat service to use `user_id` (session user ID) instead of `creator_id`:
```typescript
// ❌ OLD - Don't do this
const initResponse = await fetch('/api/conversations/initialize', {
  method: 'POST',
  body: JSON.stringify({
    creator_id: creatorProfile.id,  // Wrong parameter
    session_id: sessionId
  })
});

// ✅ NEW - Do this instead
const initResponse = await fetch('/api/conversations/initialize', {
  method: 'POST',
  credentials: 'include', // Include auth session
  body: JSON.stringify({
    user_id: session.user.id,  // Use Better Auth user ID
    session_id: sessionId
  })
});
```

## Flow Diagram

```
User Login Success → Dashboard Load
       ↓
Check Creator Profile (GET /api/creator/profile)
       ↓
   Has Profile?
       ↓
    [YES] → Load Dashboard
       ↓
    [NO] → Create Profile (POST /api/creator/profile)
       ↓
Store Profile → Load Dashboard
```

## Error Handling

```typescript
// Handle common errors
try {
  const profile = await creatorService.ensureCreatorProfile();
} catch (error) {
  if (error.message.includes('401')) {
    // User not authenticated - redirect to login
    router.push('/auth/signin');
  } else {
    // Other errors - show error message
    setError('Failed to set up profile. Please try again.');
  }
}
```

## Testing

Test with your existing authenticated user `cox6KxaSNCXQZlvE9DrfyYsSsmvol3lb`:
1. Login successfully
2. Dashboard should automatically create creator profile
3. Chat initialization should work with `user_id` parameter

## Security Notes

- All endpoints require authenticated Better Auth session
- Creator profiles are automatically linked to authenticated user
- No manual creator ID management needed
- Session cookies handle authentication automatically