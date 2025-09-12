'use client';

import { useState, useEffect, useCallback } from 'react';

interface AgreementVersion {
  id: string;
  version: string;
  contentHash: string;
  content: string;
  effectiveDate: string;
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

export function useAgreement() {
  const [currentVersion, setCurrentVersion] = useState<AgreementVersion | null>(null);
  const [status, setStatus] = useState<AgreementStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
        throw new Error(data.error || 'Unknown error');
      }
    } catch (err) {
      console.error('Error fetching current agreement:', err);
      setError(err instanceof Error ? err.message : 'Failed to load agreement');
    } finally {
      setLoading(false);
    }
  }, []);

  const fetchStatus = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      
      const response = await fetch('/api/agreement/status', {
        credentials: 'include',
      });

      if (!response.ok) {
        throw new Error('Failed to fetch agreement status');
      }

      const data = await response.json();
      if (data.success) {
        setStatus(data.data);
      } else {
        throw new Error(data.error || 'Unknown error');
      }
    } catch (err) {
      console.error('Error fetching agreement status:', err);
      setError(err instanceof Error ? err.message : 'Failed to load status');
    } finally {
      setLoading(false);
    }
  }, []);

  const acceptAgreement = useCallback(async (versionId: string, acceptanceMethod = 'clickwrap') => {
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
          versionId,
          acceptanceMethod,
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

      return data;
    } catch (err) {
      console.error('Error accepting agreement:', err);
      setError(err instanceof Error ? err.message : 'Failed to accept agreement');
      throw err;
    } finally {
      setLoading(false);
    }
  }, [fetchStatus]);

  const dismissBanner = useCallback(async (versionId: string) => {
    try {
      setLoading(true);
      setError(null);

      const response = await fetch('/api/agreement/banner/dismiss', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        credentials: 'include',
        body: JSON.stringify({
          versionId,
        }),
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to dismiss banner');
      }

      const data = await response.json();
      if (!data.success) {
        throw new Error(data.error || 'Failed to dismiss banner');
      }

      return data;
    } catch (err) {
      console.error('Error dismissing banner:', err);
      setError(err instanceof Error ? err.message : 'Failed to dismiss banner');
      throw err;
    } finally {
      setLoading(false);
    }
  }, []);

  const refresh = useCallback(async () => {
    await Promise.all([fetchCurrentVersion(), fetchStatus()]);
  }, [fetchCurrentVersion, fetchStatus]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return {
    currentVersion,
    status,
    loading,
    error,
    acceptAgreement,
    dismissBanner,
    refresh,
    fetchCurrentVersion,
    fetchStatus,
  };
}