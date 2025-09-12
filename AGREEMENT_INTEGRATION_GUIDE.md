# EarnLayer Agreement System Integration Guide

## Overview
This guide provides step-by-step instructions for integrating the clickwrap agreement system into your auth flow and dashboard.

## 1. Sign-Up Form Integration

### Add Agreement Checkbox to Registration

```tsx
import { AgreementCheckbox } from '@/components/agreement/AgreementCheckbox';
import { useState } from 'react';

export function SignUpForm() {
  const [agreementAccepted, setAgreementAccepted] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (formData: FormData) => {
    if (!agreementAccepted) {
      alert('Please accept the Publisher Agreement to continue');
      return;
    }

    setIsSubmitting(true);
    // Your existing sign-up logic here
    
    // After successful user creation, the agreement will be 
    // automatically accepted via the AgreementCheckbox component
  };

  return (
    <form onSubmit={handleSubmit}>
      {/* Your existing form fields */}
      
      {/* Add agreement checkbox before submit button */}
      <div className="mt-6">
        <AgreementCheckbox
          onAcceptanceChange={setAgreementAccepted}
          disabled={isSubmitting}
          required={true}
          showViewLink={true}
        />
      </div>

      <button 
        type="submit" 
        disabled={!agreementAccepted || isSubmitting}
        className="w-full mt-4 bg-blue-600 text-white py-2 px-4 rounded disabled:opacity-50"
      >
        Create Account
      </button>
    </form>
  );
}
```

### Key Points:
- Agreement checkbox must be **unchecked by default** (legal requirement)
- Submit button should be **disabled** until agreement is accepted
- The `AgreementCheckbox` component handles the API call to accept the agreement
- No additional backend work needed - component manages acceptance automatically

## 2. Dashboard Integration

### Add Agreement Banner for Updates

```tsx
import { AgreementBanner } from '@/components/agreement/AgreementBanner';
import { useAgreement } from '@/hooks/useAgreement';

export function DashboardLayout({ children }: { children: React.ReactNode }) {
  const { status, currentVersion, acceptAgreement, dismissBanner } = useAgreement();

  const handleAcceptAgreement = async () => {
    if (currentVersion) {
      await acceptAgreement(currentVersion.id);
    }
  };

  const handleDismissBanner = async () => {
    if (currentVersion) {
      await dismissBanner(currentVersion.id);
    }
  };

  const handleViewAgreement = () => {
    // Open agreement in modal or new tab
    window.open('/agreement', '_blank');
  };

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Show banner if user needs to accept new agreement */}
      {status?.needsUpdate && currentVersion && (
        <AgreementBanner
          version={{
            id: currentVersion.id,
            version: currentVersion.version,
            effectiveDate: currentVersion.effectiveDate,
          }}
          onAccept={handleAcceptAgreement}
          onDismiss={handleDismissBanner}
          onViewAgreement={handleViewAgreement}
          type="update" // or "required" for mandatory acceptance
          className="mb-4"
        />
      )}

      {/* Your existing dashboard content */}
      <main>{children}</main>
    </div>
  );
}
```

### Add Agreement Status Widget

```tsx
import { AgreementStatus } from '@/components/agreement/AgreementStatus';

export function ProfileSettings() {
  const handleViewAgreement = () => {
    window.open('/agreement', '_blank');
  };

  return (
    <div className="space-y-6">
      {/* Your existing settings */}
      
      {/* Agreement status section */}
      <div className="bg-white rounded-lg shadow p-6">
        <h3 className="text-lg font-medium mb-4">Legal Agreements</h3>
        <AgreementStatus
          onViewAgreement={handleViewAgreement}
          showActions={true}
          compact={false}
        />
      </div>
    </div>
  );
}
```

## 3. Agreement Viewing Page

Create a dedicated page to display the current agreement:

```tsx
// pages/agreement.tsx or app/agreement/page.tsx
import { useAgreement } from '@/hooks/useAgreement';

export default function AgreementPage() {
  const { currentVersion, loading } = useAgreement();

  if (loading) {
    return <div className="flex justify-center p-8">Loading agreement...</div>;
  }

  if (!currentVersion) {
    return <div className="flex justify-center p-8">Agreement not found</div>;
  }

  return (
    <div className="max-w-4xl mx-auto p-6">
      <div className="bg-white rounded-lg shadow-lg p-8">
        <div className="mb-6">
          <h1 className="text-2xl font-bold text-gray-900">
            EarnLayer Publisher Agreement
          </h1>
          <div className="text-sm text-gray-600 mt-2">
            Version {currentVersion.version} • 
            Effective {new Date(currentVersion.effectiveDate).toLocaleDateString()}
          </div>
        </div>

        {/* Render agreement content as markdown */}
        <div 
          className="prose max-w-none"
          dangerouslySetInnerHTML={{ 
            __html: currentVersion.content.replace(/\n/g, '<br/>') 
          }}
        />
      </div>
    </div>
  );
}
```

## 4. Admin Interface (Optional)

For admin users to manage agreement versions:

```tsx
import { useState } from 'react';

export function AdminAgreementManager() {
  const [newVersion, setNewVersion] = useState('');
  const [content, setContent] = useState('');
  const [changeSummary, setChangeSummary] = useState('');

  const handleCreateVersion = async () => {
    const response = await fetch('/api/admin/agreements', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({
        versionString: newVersion,
        content,
        changeSummary,
      }),
    });

    if (response.ok) {
      alert('Agreement version created successfully');
      // Reset form
      setNewVersion('');
      setContent('');
      setChangeSummary('');
    }
  };

  return (
    <div className="max-w-4xl mx-auto p-6">
      <h1 className="text-2xl font-bold mb-6">Agreement Management</h1>
      
      <div className="space-y-4">
        <input
          type="text"
          placeholder="Version (e.g., 1.1.0)"
          value={newVersion}
          onChange={(e) => setNewVersion(e.target.value)}
          className="w-full p-2 border rounded"
        />
        
        <textarea
          placeholder="Agreement content (markdown supported)"
          value={content}
          onChange={(e) => setContent(e.target.value)}
          rows={20}
          className="w-full p-2 border rounded font-mono text-sm"
        />
        
        <input
          type="text"
          placeholder="Change summary"
          value={changeSummary}
          onChange={(e) => setChangeSummary(e.target.value)}
          className="w-full p-2 border rounded"
        />
        
        <button
          onClick={handleCreateVersion}
          className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
        >
          Create New Version
        </button>
      </div>
    </div>
  );
}
```

## 5. Required Auth Flow Updates

### Update User Model Validation

If you want to enforce agreement acceptance before platform access:

```tsx
// In your auth middleware or protected route handler
export async function requiresAgreementAcceptance(userId: string) {
  const response = await fetch(`/api/agreement/status`, {
    headers: { 'Authorization': `Bearer ${token}` }
  });
  
  const data = await response.json();
  
  if (!data.data.hasAcceptedCurrent) {
    // Redirect to agreement acceptance page
    return { redirect: '/accept-agreement' };
  }
  
  return { allowed: true };
}
```

### Create Agreement Acceptance Page

```tsx
// pages/accept-agreement.tsx
export default function AcceptAgreementPage() {
  const { currentVersion, acceptAgreement } = useAgreement();
  const [isAccepting, setIsAccepting] = useState(false);

  const handleAccept = async () => {
    if (!currentVersion) return;
    
    setIsAccepting(true);
    try {
      await acceptAgreement(currentVersion.id);
      // Redirect to dashboard
      window.location.href = '/dashboard';
    } catch (error) {
      alert('Failed to accept agreement');
    } finally {
      setIsAccepting(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50">
      <div className="max-w-2xl mx-auto p-6">
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
          <h1 className="text-xl font-bold text-red-800 mb-2">
            Agreement Acceptance Required
          </h1>
          <p className="text-red-700">
            You must accept the current Publisher Agreement to continue using the platform.
          </p>
        </div>

        {currentVersion && (
          <div className="bg-white rounded-lg shadow p-6">
            <div className="prose max-w-none mb-6">
              {/* Display agreement content */}
            </div>
            
            <button
              onClick={handleAccept}
              disabled={isAccepting}
              className="w-full bg-blue-600 text-white py-3 px-4 rounded font-medium hover:bg-blue-700 disabled:opacity-50"
            >
              {isAccepting ? 'Accepting...' : 'I Accept the Agreement'}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
```

## 6. Testing Checklist

- [ ] Sign-up form shows agreement checkbox (unchecked by default)
- [ ] Submit button disabled until agreement accepted
- [ ] Agreement acceptance recorded in database after sign-up
- [ ] Dashboard shows banner for agreement updates
- [ ] Banner can be accepted or dismissed
- [ ] Agreement status widget displays correctly
- [ ] Agreement viewing page renders content properly
- [ ] Admin interface creates new versions (if implemented)
- [ ] Protected routes enforce agreement acceptance (if implemented)

## 7. API Endpoints Reference

- `GET /api/agreement/current` - Get current agreement (public)
- `GET /api/agreement/status` - User's agreement status (auth required)
- `POST /api/agreement/accept` - Accept agreement (auth required)
- `POST /api/agreement/banner/dismiss` - Dismiss banner (auth required)
- `GET /api/admin/agreements` - Admin view (admin auth required)
- `POST /api/admin/agreements` - Create new version (admin auth required)

## 8. Legal Compliance Notes

- Agreement checkbox MUST be unchecked by default
- Users must actively click to accept (no pre-checked boxes)
- All acceptances are logged with timestamp, IP, and user agent
- Content integrity maintained via SHA-256 hashing
- Full audit trail available for legal purposes
- Version control maintains history of all agreement changes