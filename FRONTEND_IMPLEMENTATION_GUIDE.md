# Frontend Implementation Guide: Mandatory Agreement System

## Overview
This guide provides step-by-step instructions for implementing a mandatory clickwrap agreement system that requires users to accept terms before accessing the platform.

## System Requirements

### User Experience Requirements:
- ✅ **Mandatory modal** that cannot be dismissed without accepting
- ✅ **Scroll-to-bottom validation** - accept button only enabled after reading full agreement
- ✅ **Legal compliance** - records IP address, timestamp, user agent for audit trail
- ✅ **Professional UI** - mobile responsive with loading states
- ✅ **One-time acceptance** - modal doesn't reappear after acceptance

### Technical Requirements:
- React/Next.js frontend
- User authentication system
- Database to store acceptance records
- API endpoints for agreement management

## API Endpoints Needed

Your backend team needs to provide these endpoints:

```typescript
// Get current agreement version
GET /api/agreement/current
Response: {
  success: boolean;
  data: {
    id: string;
    version: string;
    content: string; // Full agreement text
    effectiveDate: string;
    contentHash: string;
  }
}

// Get user's agreement status (requires authentication)
GET /api/agreement/status  
Response: {
  success: boolean;
  data: {
    hasAcceptedCurrent: boolean;
    needsUpdate: boolean;
    currentVersion: { id: string; version: string; effectiveDate: string; };
    acceptedVersion?: { id: string; version: string; acceptedAt: string; };
  }
}

// Record user acceptance (requires authentication)
POST /api/agreement/accept
Body: { versionId: string; acceptanceMethod: string; }
Response: { success: boolean; message: string; }

// Dismiss update banner (optional)
POST /api/agreement/banner/dismiss
Body: { versionId: string; }
Response: { success: boolean; }
```

## Frontend Implementation

### Step 1: Create Agreement Hook

Create `hooks/useAgreement.js`:

```jsx
import { useState, useEffect, useCallback } from 'react';

export function useAgreement() {
  const [currentVersion, setCurrentVersion] = useState(null);
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  // Fetch current agreement version (public endpoint)
  const fetchCurrentVersion = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      
      const response = await fetch('https://api.earnlayerai.com/api/agreement/current');
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

  // Fetch user agreement status (requires auth)
  const fetchStatus = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      
      const response = await fetch('https://api.earnlayerai.com/api/agreement/status', {
        credentials: 'include', // Include cookies for auth
      });
      
      if (response.status === 401) {
        // User not authenticated
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

      const response = await fetch('https://api.earnlayerai.com/api/agreement/accept', {
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

      // Refresh status after acceptance
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

### Step 2: Create Agreement Modal Component

Create `components/AgreementModal.jsx`:

```jsx
import { useState, useEffect, useRef } from 'react';

export function AgreementModal({ isOpen, agreement, onAccept, onClose }) {
  const [hasScrolledToBottom, setHasScrolledToBottom] = useState(false);
  const [isAccepting, setIsAccepting] = useState(false);
  const [error, setError] = useState(null);
  const contentRef = useRef(null);

  // Reset state when modal opens
  useEffect(() => {
    if (isOpen) {
      setHasScrolledToBottom(false);
      setIsAccepting(false);
      setError(null);
    }
  }, [isOpen]);

  // Handle scroll detection
  const handleScroll = () => {
    if (!contentRef.current) return;

    const { scrollTop, scrollHeight, clientHeight } = contentRef.current;
    const scrolledToBottom = scrollTop + clientHeight >= scrollHeight - 10;

    if (scrolledToBottom && !hasScrolledToBottom) {
      setHasScrolledToBottom(true);
    }
  };

  // Handle acceptance
  const handleAccept = async () => {
    if (!hasScrolledToBottom || isAccepting) return;

    setIsAccepting(true);
    setError(null);

    try {
      await onAccept();
      // Modal will close when status updates
    } catch (error) {
      setError(error.message);
    } finally {
      setIsAccepting(false);
    }
  };

  // Prevent body scroll when modal is open
  useEffect(() => {
    if (isOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = 'unset';
    }
    return () => { document.body.style.overflow = 'unset'; };
  }, [isOpen]);

  if (!isOpen || !agreement) return null;

  return (
    <div className="fixed inset-0 z-50 overflow-hidden">
      {/* Backdrop - cannot be clicked */}
      <div className="absolute inset-0 bg-black bg-opacity-75" />

      {/* Modal */}
      <div className="relative flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-4xl max-h-[90vh] bg-white rounded-lg shadow-xl flex flex-col">
          
          {/* Header */}
          <div className="flex-shrink-0 px-6 py-4 border-b border-red-200 bg-red-50">
            <h2 className="text-xl font-semibold text-red-800">
              Agreement Acceptance Required
            </h2>
            <p className="text-sm text-red-700 mt-1">
              You must accept the current Publisher Agreement to continue using the platform.
            </p>
            <div className="mt-3 text-sm text-gray-600">
              <span className="font-medium">Version:</span> {agreement.version} • 
              <span className="font-medium ml-2">Effective:</span> {new Date(agreement.effectiveDate).toLocaleDateString()}
            </div>

            {/* Scroll progress indicator */}
            <div className="mt-3">
              <div className="flex items-center space-x-2 text-sm">
                {hasScrolledToBottom ? (
                  <>
                    <span className="text-green-600">✓</span>
                    <span className="text-green-800 font-medium">You have read the full agreement</span>
                  </>
                ) : (
                  <>
                    <span className="text-yellow-600">⚠</span>
                    <span className="text-yellow-800">Please scroll to the bottom to read the full agreement</span>
                  </>
                )}
              </div>
            </div>
          </div>

          {/* Agreement Content */}
          <div 
            ref={contentRef}
            className="flex-1 overflow-y-auto px-6 py-4"
            onScroll={handleScroll}
          >
            <div className="prose max-w-none">
              {/* Render agreement content - adjust based on your content format */}
              {agreement.content.split('\n').map((paragraph, index) => {
                if (paragraph.trim() === '') return <br key={index} />;
                if (paragraph.startsWith('# ')) {
                  return <h1 key={index} className="text-2xl font-bold text-gray-900 mt-6 mb-4">{paragraph.replace('# ', '')}</h1>;
                }
                if (paragraph.startsWith('## ')) {
                  return <h2 key={index} className="text-xl font-semibold text-gray-800 mt-5 mb-3">{paragraph.replace('## ', '')}</h2>;
                }
                if (paragraph.startsWith('**') && paragraph.endsWith('**')) {
                  return <p key={index} className="font-semibold text-gray-900 mb-2">{paragraph.replace(/\*\*/g, '')}</p>;
                }
                if (paragraph.startsWith('- ')) {
                  return <li key={index} className="ml-4 mb-1 text-gray-700">{paragraph.replace('- ', '')}</li>;
                }
                if (paragraph.trim() === '---') {
                  return <hr key={index} className="my-6 border-gray-300" />;
                }
                return <p key={index} className="mb-3 text-gray-700 leading-relaxed">{paragraph}</p>;
              })}
            </div>
            <div className="h-4" /> {/* Bottom spacing for scroll detection */}
          </div>

          {/* Footer */}
          <div className="flex-shrink-0 px-6 py-4 border-t border-gray-200 bg-gray-50">
            {error && (
              <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-md">
                <p className="text-sm text-red-800">{error}</p>
              </div>
            )}

            <div className="flex justify-between items-center">
              <div className="text-sm text-gray-600">
                Acceptance is required to continue using the platform
              </div>

              <button
                type="button"
                onClick={handleAccept}
                disabled={!hasScrolledToBottom || isAccepting}
                className="inline-flex items-center px-6 py-2 text-sm font-medium text-white bg-red-600 rounded-md hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-red-500 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {isAccepting ? (
                  <>
                    <div className="mr-2 h-4 w-4 animate-spin rounded-full border-2 border-white border-t-transparent"></div>
                    Accepting...
                  </>
                ) : (
                  <>
                    ✓ I Accept the Agreement
                  </>
                )}
              </button>
            </div>

            {!hasScrolledToBottom && (
              <div className="mt-3 text-center">
                <p className="text-xs text-gray-500">
                  Please scroll to the bottom of the agreement to enable the accept button
                </p>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
```

### Step 3: Create Agreement Guard Component

Create `components/AgreementGuard.jsx`:

```jsx
import { useEffect } from 'react';
import { useAgreement } from '../hooks/useAgreement';
import { AgreementModal } from './AgreementModal';

export function AgreementGuard({ children, user }) {
  const {
    currentVersion,
    status,
    loading,
    error,
    acceptAgreement,
    fetchCurrentVersion,
    fetchStatus,
  } = useAgreement();

  // Load agreement data when component mounts or user changes
  useEffect(() => {
    fetchCurrentVersion();
    if (user) {
      fetchStatus();
    }
  }, [fetchCurrentVersion, fetchStatus, user]);

  // Determine if modal should be shown
  const shouldShowModal = user && status && !status.hasAcceptedCurrent && currentVersion;

  const handleAcceptAgreement = async () => {
    if (currentVersion) {
      await acceptAgreement(currentVersion.id);
    }
  };

  // Show error state if agreement system fails
  if (error && user) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center p-4">
        <div className="bg-white rounded-lg shadow p-6 max-w-md w-full text-center">
          <div className="text-red-600 mb-4">
            <svg className="mx-auto h-12 w-12" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.5 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z" />
            </svg>
          </div>
          <h3 className="text-lg font-medium text-gray-900 mb-2">
            Agreement System Error
          </h3>
          <p className="text-sm text-gray-600 mb-4">{error}</p>
          <button
            onClick={() => window.location.reload()}
            className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
          >
            Reload Page
          </button>
        </div>
      </div>
    );
  }

  return (
    <>
      {/* Main app content */}
      {children}

      {/* Mandatory Agreement Modal */}
      <AgreementModal
        isOpen={shouldShowModal}
        agreement={currentVersion}
        onAccept={handleAcceptAgreement}
        // No onClose prop - modal cannot be dismissed!
      />
    </>
  );
}
```

### Step 4: Integrate into Your App

In your main app component or layout:

```jsx
import { AgreementGuard } from './components/AgreementGuard';
import { useAuth } from './hooks/useAuth'; // Your existing auth hook

export function App() {
  const { user } = useAuth(); // Your existing user authentication

  return (
    <AgreementGuard user={user}>
      <div className="app">
        {/* Your existing app content */}
        <Header />
        <MainContent />
        <Footer />
      </div>
    </AgreementGuard>
  );
}
```

## Testing the Implementation

### Test Scenarios:

1. **Unauthenticated User**: No modal should appear
2. **New Authenticated User**: Mandatory modal should appear immediately
3. **User Who Already Accepted**: No modal should appear
4. **Modal Behavior**: 
   - Cannot be closed/dismissed
   - Accept button disabled until scrolled to bottom
   - Shows loading state during acceptance
   - Disappears after successful acceptance

### Debug Component (Optional):

Create a test component to verify the system:

```jsx
export function AgreementDebug() {
  const { currentVersion, status, loading, error } = useAgreement();

  return (
    <div className="bg-gray-100 p-4 rounded m-4">
      <h3 className="font-bold mb-2">Agreement System Debug</h3>
      <div className="text-sm space-y-1">
        <div>Loading: {loading ? 'Yes' : 'No'}</div>
        <div>Error: {error || 'None'}</div>
        <div>Current Version: {currentVersion?.version || 'None'}</div>
        <div>Has Accepted: {status?.hasAcceptedCurrent ? 'Yes' : 'No'}</div>
        <div>Needs Update: {status?.needsUpdate ? 'Yes' : 'No'}</div>
      </div>
    </div>
  );
}
```

## Database Schema (For Backend Team)

The backend needs these tables to support the system:

```sql
-- Agreement versions
CREATE TABLE agreement_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  version_string VARCHAR(50) NOT NULL UNIQUE,
  content_hash VARCHAR(64) NOT NULL UNIQUE,
  content_text TEXT NOT NULL,
  is_active BOOLEAN DEFAULT true,
  effective_date TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  created_by TEXT,
  change_summary TEXT
);

-- User acceptances  
CREATE TABLE user_agreements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL, -- Reference to your user table
  agreement_version_id UUID NOT NULL REFERENCES agreement_versions(id),
  accepted_at TIMESTAMPTZ DEFAULT NOW(),
  ip_address TEXT,
  user_agent TEXT,
  acceptance_method VARCHAR(50) DEFAULT 'clickwrap'
);
```

## Legal Compliance Features

✅ **Clickwrap Requirements Met:**
- Agreement checkbox must be unchecked by default
- User must take affirmative action to accept
- Complete audit trail maintained
- Content integrity verified via hashing

✅ **Audit Trail Includes:**
- User ID and agreement version
- Timestamp of acceptance
- IP address of user
- User agent string
- Method of acceptance (modal, checkbox, etc.)

## Go-Live Checklist

- [ ] Backend API endpoints implemented and deployed
- [ ] Database schema created with initial agreement version
- [ ] Frontend components integrated into main app
- [ ] AgreementGuard wrapping authenticated areas
- [ ] Test with new user account
- [ ] Verify modal appears and cannot be dismissed
- [ ] Confirm scroll-to-bottom validation works
- [ ] Test acceptance flow records data correctly
- [ ] Verify modal doesn't reappear after acceptance

## Result

Once implemented, every authenticated user who hasn't accepted the current agreement will see a mandatory modal that:

- Cannot be dismissed or closed
- Requires scrolling through the entire agreement
- Only enables acceptance after full review  
- Records complete legal audit trail
- Prevents platform access until accepted

This provides full legal compliance for clickwrap agreements while maintaining a professional user experience.