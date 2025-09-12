'use client';

import { useSession } from '@/lib/auth/client';
import { useAgreement } from '@/hooks/useAgreement';

export default function TestAgreementPage() {
  const { data: session } = useSession();
  const { status, currentVersion, loading, error } = useAgreement();

  return (
    <div className="max-w-4xl mx-auto p-6">
      <h1 className="text-3xl font-bold mb-6">Agreement System Test</h1>
      
      <div className="space-y-6">
        {/* Session Info */}
        <div className="bg-white p-6 rounded-lg shadow">
          <h2 className="text-xl font-semibold mb-4">Session Status</h2>
          {session ? (
            <div className="space-y-2">
              <p><strong>User ID:</strong> {session.user.id}</p>
              <p><strong>Email:</strong> {session.user.email}</p>
              <p><strong>Name:</strong> {session.user.name}</p>
            </div>
          ) : (
            <p className="text-gray-600">Not authenticated</p>
          )}
        </div>

        {/* Current Agreement */}
        <div className="bg-white p-6 rounded-lg shadow">
          <h2 className="text-xl font-semibold mb-4">Current Agreement</h2>
          {loading ? (
            <p className="text-gray-600">Loading...</p>
          ) : error ? (
            <p className="text-red-600">Error: {error}</p>
          ) : currentVersion ? (
            <div className="space-y-2">
              <p><strong>Version:</strong> {currentVersion.version}</p>
              <p><strong>Effective Date:</strong> {new Date(currentVersion.effectiveDate).toLocaleDateString()}</p>
              <p><strong>Content Hash:</strong> {currentVersion.contentHash}</p>
            </div>
          ) : (
            <p className="text-gray-600">No agreement found</p>
          )}
        </div>

        {/* User Agreement Status */}
        <div className="bg-white p-6 rounded-lg shadow">
          <h2 className="text-xl font-semibold mb-4">Agreement Status</h2>
          {!session ? (
            <p className="text-gray-600">Please log in to see agreement status</p>
          ) : loading ? (
            <p className="text-gray-600">Loading...</p>
          ) : error ? (
            <p className="text-red-600">Error: {error}</p>
          ) : status ? (
            <div className="space-y-2">
              <p><strong>Has Accepted Current:</strong> {status.hasAcceptedCurrent ? '✅ Yes' : '❌ No'}</p>
              <p><strong>Needs Update:</strong> {status.needsUpdate ? '⚠️ Yes' : '✅ No'}</p>
              <p><strong>Current Version:</strong> {status.currentVersion.version}</p>
              {status.acceptedVersion && (
                <div>
                  <p><strong>Accepted Version:</strong> {status.acceptedVersion.version}</p>
                  <p><strong>Accepted At:</strong> {new Date(status.acceptedVersion.acceptedAt).toLocaleString()}</p>
                </div>
              )}
            </div>
          ) : (
            <p className="text-gray-600">No status available</p>
          )}
        </div>

        {/* Instructions */}
        <div className="bg-blue-50 p-6 rounded-lg border border-blue-200">
          <h2 className="text-xl font-semibold mb-4 text-blue-800">Test Instructions</h2>
          <div className="text-blue-700 space-y-2">
            <p>1. If you're not logged in, log in to test the agreement system</p>
            <p>2. If you haven't accepted the current agreement, a modal should appear</p>
            <p>3. You must scroll to the bottom of the agreement to enable the accept button</p>
            <p>4. After accepting, this page should show your acceptance status</p>
            <p>5. The modal should not appear again until a new agreement version is created</p>
          </div>
        </div>
      </div>
    </div>
  );
}