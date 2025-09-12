'use client';

import { useState, useEffect, useCallback } from 'react';
import { useSession } from '@/lib/auth/client';

interface AgreementVersion {
  id: string;
  version: string;
  content: string;
  effectiveDate: string;
  contentHash: string;
}

interface AgreementStatus {
  hasAcceptedCurrent: boolean;
  needsUpdate: boolean;
  currentVersion: {
    id: string;
    version: string;
    effectiveDate: string;
  };
  acceptedVersion?: {
    id: string;
    version: string;
    acceptedAt: string;
  };
}

export function useAgreementGuard() {
  const { data: session, isPending: sessionLoading } = useSession();
  const [currentVersion, setCurrentVersion] = useState<AgreementVersion | null>(null);
  const [status, setStatus] = useState<AgreementStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showModal, setShowModal] = useState(false);

  // Check if user needs to accept agreement
  const needsAcceptance = status && !status.hasAcceptedCurrent;

  const fetchCurrentVersion = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      
      const response = await fetch('/api/agreement/current', {
        credentials: 'include',
      });

      if (!response.ok) {
        throw new Error('Failed to fetch current agreement');
      }

      const data = await response.json();
      if (data.success) {
        setCurrentVersion(data.data);
      } else {
        throw new Error(data.error || 'Failed to load agreement');
      }
    } catch (err) {
      console.error('Error fetching current agreement:', err);
      setError(err instanceof Error ? err.message : 'Failed to load agreement');
    } finally {
      setLoading(false);
    }
  }, []);

  const fetchStatus = useCallback(async () => {
    if (!session?.user) {
      setStatus(null);
      return;
    }

    try {
      setLoading(true);
      setError(null);
      
      const response = await fetch('/api/agreement/status', {
        credentials: 'include',
      });

      if (!response.ok) {
        if (response.status === 401) {
          // User not authenticated, don't show error
          setStatus(null);
          return;
        }
        throw new Error('Failed to fetch agreement status');
      }

      const data = await response.json();
      if (data.success) {
        setStatus(data.data);
      } else {
        throw new Error(data.error || 'Failed to load status');
      }
    } catch (err) {
      console.error('Error fetching agreement status:', err);
      setError(err instanceof Error ? err.message : 'Failed to load status');
    } finally {
      setLoading(false);
    }
  }, [session?.user]);

  const acceptAgreement = useCallback(async () => {
    if (!currentVersion || !session?.user) {
      throw new Error('No agreement version or user session found');
    }

    try {
      setLoading(true);
      setError(null);

      const response = await fetch('/api/agreement/accept', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        credentials: 'include',
        body: JSON.stringify({
          versionId: currentVersion.id,
          acceptanceMethod: 'modal',
        }),
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to accept agreement');
      }

      const data = await response.json();
      if (!data.success) {
        throw new Error(data.error || 'Failed to accept agreement');
      }

      // Refresh status after acceptance
      await fetchStatus();
      
      // Hide modal
      setShowModal(false);

      return data;
    } catch (err) {
      console.error('Error accepting agreement:', err);
      setError(err instanceof Error ? err.message : 'Failed to accept agreement');
      throw err;
    } finally {
      setLoading(false);
    }
  }, [currentVersion, session?.user, fetchStatus]);

  // Load agreement data when component mounts or session changes
  useEffect(() => {
    fetchCurrentVersion();
    
    if (session?.user) {
      fetchStatus();
    }
  }, [fetchCurrentVersion, fetchStatus, session?.user]);

  // Show modal when user needs to accept agreement
  useEffect(() => {
    if (!sessionLoading && session?.user && status && needsAcceptance && currentVersion) {
      setShowModal(true);
    } else {
      setShowModal(false);
    }
  }, [sessionLoading, session?.user, status, needsAcceptance, currentVersion]);

  const refresh = useCallback(async () => {
    await Promise.all([fetchCurrentVersion(), fetchStatus()]);
  }, [fetchCurrentVersion, fetchStatus]);

  return {
    // Data
    currentVersion,
    status,
    session,
    
    // State
    loading: loading || sessionLoading,
    error,
    showModal,
    needsAcceptance,
    
    // Actions
    acceptAgreement,
    refresh,
    
    // Manual control (for testing or special cases)
    setShowModal,
  };
}