'use client';

import { useState, useEffect } from 'react';
import { Check, AlertTriangle, FileText, Clock } from 'lucide-react';

interface AgreementStatusData {
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

interface AgreementStatusProps {
  className?: string;
  compact?: boolean;
  onViewAgreement?: () => void;
  showActions?: boolean;
}

export const AgreementStatus: React.FC<AgreementStatusProps> = ({
  className = '',
  compact = false,
  onViewAgreement,
  showActions = true
}) => {
  const [status, setStatus] = useState<AgreementStatusData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchStatus();
  }, []);

  const fetchStatus = async () => {
    try {
      setLoading(true);
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
      setError(err instanceof Error ? err.message : 'Failed to load agreement status');
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return (
      <div className={`animate-pulse ${className}`}>
        <div className="flex items-center space-x-3">
          <div className="h-5 w-5 bg-gray-300 rounded"></div>
          <div className="space-y-2">
            <div className="h-4 w-32 bg-gray-300 rounded"></div>
            <div className="h-3 w-24 bg-gray-300 rounded"></div>
          </div>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className={`flex items-center space-x-2 text-red-600 ${className}`}>
        <AlertTriangle className="h-4 w-4" />
        <span className="text-sm">{error}</span>
      </div>
    );
  }

  if (!status) {
    return null;
  }

  const getStatusIcon = () => {
    if (status.hasAcceptedCurrent) {
      return <Check className="h-5 w-5 text-green-600" />;
    } else {
      return <AlertTriangle className="h-5 w-5 text-yellow-600" />;
    }
  };

  const getStatusText = () => {
    if (status.hasAcceptedCurrent) {
      return {
        title: 'Agreement Current',
        description: `Accepted version ${status.acceptedVersion?.version} on ${
          status.acceptedVersion?.acceptedAt 
            ? new Date(status.acceptedVersion.acceptedAt).toLocaleDateString()
            : 'Unknown date'
        }`,
        color: 'text-green-800'
      };
    } else {
      return {
        title: 'Agreement Update Needed',
        description: `Current version ${status.currentVersion.version} requires acceptance`,
        color: 'text-yellow-800'
      };
    }
  };

  const statusInfo = getStatusText();

  if (compact) {
    return (
      <div className={`flex items-center space-x-2 ${className}`}>
        {getStatusIcon()}
        <span className={`text-sm font-medium ${statusInfo.color}`}>
          {statusInfo.title}
        </span>
        {status.needsUpdate && (
          <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800">
            Action Required
          </span>
        )}
      </div>
    );
  }

  return (
    <div className={`bg-white rounded-lg border border-gray-200 p-4 ${className}`}>
      <div className="flex items-start justify-between">
        <div className="flex items-start space-x-3">
          {getStatusIcon()}
          <div>
            <h3 className={`text-sm font-medium ${statusInfo.color}`}>
              {statusInfo.title}
            </h3>
            <p className="text-sm text-gray-600 mt-1">
              {statusInfo.description}
            </p>
            {status.needsUpdate && (
              <div className="mt-2">
                <span className="inline-flex items-center px-2 py-1 rounded-md text-xs font-medium bg-yellow-100 text-yellow-800">
                  <Clock className="mr-1 h-3 w-3" />
                  Update Required
                </span>
              </div>
            )}
          </div>
        </div>
        
        {showActions && onViewAgreement && (
          <button
            onClick={onViewAgreement}
            className="flex items-center text-sm text-blue-600 hover:text-blue-800 hover:underline"
          >
            <FileText className="mr-1 h-4 w-4" />
            View Agreement
          </button>
        )}
      </div>

      {!compact && (
        <div className="mt-4 pt-4 border-t border-gray-200">
          <dl className="grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-2">
            <div>
              <dt className="text-xs font-medium text-gray-500">Current Version</dt>
              <dd className="text-sm text-gray-900">{status.currentVersion.version}</dd>
            </div>
            <div>
              <dt className="text-xs font-medium text-gray-500">Effective Date</dt>
              <dd className="text-sm text-gray-900">
                {new Date(status.currentVersion.effectiveDate).toLocaleDateString()}
              </dd>
            </div>
            {status.acceptedVersion && (
              <>
                <div>
                  <dt className="text-xs font-medium text-gray-500">Accepted Version</dt>
                  <dd className="text-sm text-gray-900">{status.acceptedVersion.version}</dd>
                </div>
                <div>
                  <dt className="text-xs font-medium text-gray-500">Accepted Date</dt>
                  <dd className="text-sm text-gray-900">
                    {new Date(status.acceptedVersion.acceptedAt).toLocaleDateString()}
                  </dd>
                </div>
              </>
            )}
          </dl>
        </div>
      )}
    </div>
  );
};