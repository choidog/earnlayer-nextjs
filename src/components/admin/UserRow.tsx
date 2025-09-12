'use client';

import { useState } from 'react';

interface User {
  id: string;
  email: string;
  name: string;
  createdAt: string;
  emailVerified: boolean;
  approvalStatus: 'pending' | 'approved' | 'rejected' | 'suspended';
  approvalDate?: string;
  rejectionReason?: string;
  apiKeyCount: number;
  lastLoginAt?: string;
  hasCreatorProfile: boolean;
}

interface UserRowProps {
  user: User;
  isSelected: boolean;
  onToggleSelect: () => void;
  onStatusUpdate: (userId: string, newStatus: string, reason?: string) => Promise<void>;
}

const StatusBadge: React.FC<{ status: string }> = ({ status }) => {
  const badges = {
    pending: { color: 'text-yellow-800', bg: 'bg-yellow-100', text: '⏳ Pending' },
    approved: { color: 'text-green-800', bg: 'bg-green-100', text: '✅ Approved' },
    rejected: { color: 'text-red-800', bg: 'bg-red-100', text: '❌ Rejected' },
    suspended: { color: 'text-gray-800', bg: 'bg-gray-100', text: '🚫 Suspended' }
  };
  
  const badge = badges[status as keyof typeof badges] || badges.pending;
  
  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${badge.bg} ${badge.color}`}>
      {badge.text}
    </span>
  );
};

export const UserRow: React.FC<UserRowProps> = ({
  user,
  isSelected,
  onToggleSelect,
  onStatusUpdate
}) => {
  const [updating, setUpdating] = useState(false);
  const [showRejectModal, setShowRejectModal] = useState(false);

  const handleStatusChange = async (newStatus: string, reason?: string) => {
    setUpdating(true);
    try {
      await onStatusUpdate(user.id, newStatus, reason);
    } finally {
      setUpdating(false);
      setShowRejectModal(false);
    }
  };

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    });
  };

  const formatDateTime = (dateString: string) => {
    return new Date(dateString).toLocaleString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  };

  return (
    <>
      <tr className={`${isSelected ? 'bg-blue-50' : ''} hover:bg-gray-50`}>
        <td className="px-6 py-4 whitespace-nowrap">
          <input
            type="checkbox"
            checked={isSelected}
            onChange={onToggleSelect}
            className="rounded border-gray-300"
          />
        </td>
        
        <td className="px-6 py-4 whitespace-nowrap">
          <div className="flex items-center">
            <div className="flex-shrink-0 h-10 w-10">
              <div className="h-10 w-10 rounded-full bg-gray-300 flex items-center justify-center">
                <span className="text-sm font-medium text-gray-700">
                  {user.name.charAt(0).toUpperCase()}
                </span>
              </div>
            </div>
            <div className="ml-4">
              <div className="text-sm font-medium text-gray-900">
                {user.name}
                {!user.hasCreatorProfile && (
                  <span className="ml-2 text-xs text-gray-500">(No Creator Profile)</span>
                )}
              </div>
              <div className="text-sm text-gray-500">
                {user.email}
                {user.emailVerified && (
                  <span className="ml-2 text-green-600">✓</span>
                )}
              </div>
            </div>
          </div>
        </td>
        
        <td className="px-6 py-4 whitespace-nowrap">
          <StatusBadge status={user.approvalStatus} />
          {user.rejectionReason && (
            <div className="text-xs text-gray-500 mt-1" title={user.rejectionReason}>
              Reason: {user.rejectionReason.substring(0, 30)}
              {user.rejectionReason.length > 30 && '...'}
            </div>
          )}
          {user.approvalDate && (
            <div className="text-xs text-gray-500 mt-1">
              {formatDate(user.approvalDate)}
            </div>
          )}
        </td>
        
        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
          {formatDate(user.createdAt)}
        </td>
        
        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
          {user.lastLoginAt ? formatDateTime(user.lastLoginAt) : 'Never'}
        </td>
        
        <td className="px-6 py-4 whitespace-nowrap">
          <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${
            user.apiKeyCount > 0 ? 'bg-blue-100 text-blue-800' : 'bg-gray-100 text-gray-800'
          }`}>
            {user.apiKeyCount} API Keys
          </span>
        </td>
        
        <td className="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
          <div className="flex items-center space-x-2">
            {user.approvalStatus === 'pending' && (
              <>
                <button
                  onClick={() => handleStatusChange('approved')}
                  disabled={updating}
                  className="text-green-600 hover:text-green-900 disabled:opacity-50 px-2 py-1 border border-green-300 rounded text-xs hover:bg-green-50"
                >
                  ✅ Approve
                </button>
                <button
                  onClick={() => setShowRejectModal(true)}
                  disabled={updating}
                  className="text-red-600 hover:text-red-900 disabled:opacity-50 px-2 py-1 border border-red-300 rounded text-xs hover:bg-red-50"
                >
                  ❌ Reject
                </button>
              </>
            )}
            
            {user.approvalStatus === 'approved' && (
              <button
                onClick={() => handleStatusChange('suspended', 'Suspended by admin')}
                disabled={updating}
                className="text-gray-600 hover:text-gray-900 disabled:opacity-50 px-2 py-1 border border-gray-300 rounded text-xs hover:bg-gray-50"
              >
                🚫 Suspend
              </button>
            )}
            
            {(user.approvalStatus === 'rejected' || user.approvalStatus === 'suspended') && (
              <button
                onClick={() => handleStatusChange('pending')}
                disabled={updating}
                className="text-blue-600 hover:text-blue-900 disabled:opacity-50 px-2 py-1 border border-blue-300 rounded text-xs hover:bg-blue-50"
              >
                ↩️ Reset
              </button>
            )}
            
            {updating && (
              <div className="inline-block animate-spin rounded-full h-4 w-4 border-b-2 border-gray-900"></div>
            )}
          </div>
        </td>
      </tr>

      {/* Reject Modal */}
      {showRejectModal && (
        <tr>
          <td colSpan={7}>
            <div className="fixed inset-0 bg-gray-600 bg-opacity-50 overflow-y-auto h-full w-full z-50">
              <div className="relative top-20 mx-auto p-5 border w-96 shadow-lg rounded-md bg-white">
                <div className="mt-3">
                  <h3 className="text-lg font-medium text-gray-900 mb-4">
                    Reject User: {user.name}
                  </h3>
                  <textarea
                    id="rejection-reason"
                    placeholder="Enter reason for rejection..."
                    className="w-full p-3 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
                    rows={3}
                  />
                  <div className="flex justify-end mt-4 space-x-3">
                    <button
                      onClick={() => setShowRejectModal(false)}
                      className="px-4 py-2 bg-gray-300 text-gray-700 rounded-md hover:bg-gray-400"
                    >
                      Cancel
                    </button>
                    <button
                      onClick={() => {
                        const reason = (document.getElementById('rejection-reason') as HTMLTextAreaElement).value;
                        if (reason.trim()) {
                          handleStatusChange('rejected', reason);
                        }
                      }}
                      className="px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700"
                    >
                      Reject User
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
};