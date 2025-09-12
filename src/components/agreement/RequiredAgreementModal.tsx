'use client';

import { useState, useEffect, useRef } from 'react';
import { Check, FileText, AlertTriangle } from 'lucide-react';

interface AgreementVersion {
  id: string;
  version: string;
  content: string;
  effectiveDate: string;
  contentHash: string;
}

interface RequiredAgreementModalProps {
  isOpen: boolean;
  agreement: AgreementVersion | null;
  onAccept: () => Promise<void>;
  onClose?: () => void;
  canClose?: boolean;
  type?: 'required' | 'update';
}

export const RequiredAgreementModal: React.FC<RequiredAgreementModalProps> = ({
  isOpen,
  agreement,
  onAccept,
  onClose,
  canClose = false,
  type = 'required'
}) => {
  const [hasScrolledToBottom, setHasScrolledToBottom] = useState(false);
  const [isAccepting, setIsAccepting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const isRequired = type === 'required';

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
    const scrolledToBottom = scrollTop + clientHeight >= scrollHeight - 10; // 10px tolerance

    if (scrolledToBottom && !hasScrolledToBottom) {
      setHasScrolledToBottom(true);
    }
  };

  const handleAccept = async () => {
    if (isAccepting || (!hasScrolledToBottom && isRequired)) return;

    setIsAccepting(true);
    setError(null);

    try {
      await onAccept();
      // Modal will close automatically when agreement status updates
    } catch (error) {
      console.error('Failed to accept agreement:', error);
      setError(error instanceof Error ? error.message : 'Failed to accept agreement');
    } finally {
      setIsAccepting(false);
    }
  };

  const handleClose = () => {
    if (canClose && onClose && !isAccepting) {
      onClose();
    }
  };

  // Prevent scrolling on body when modal is open
  useEffect(() => {
    if (isOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = 'unset';
    }

    return () => {
      document.body.style.overflow = 'unset';
    };
  }, [isOpen]);

  if (!isOpen || !agreement) {
    return null;
  }

  const canAccept = hasScrolledToBottom || !isRequired;
  const bgColor = isRequired ? 'bg-red-50' : 'bg-blue-50';
  const borderColor = isRequired ? 'border-red-200' : 'border-blue-200';
  const textColor = isRequired ? 'text-red-800' : 'text-blue-800';
  const buttonColor = isRequired 
    ? 'bg-red-600 hover:bg-red-700 disabled:bg-red-300' 
    : 'bg-blue-600 hover:bg-blue-700 disabled:bg-blue-300';

  return (
    <div className="fixed inset-0 z-50 overflow-hidden">
      {/* Backdrop */}
      <div 
        className="absolute inset-0 bg-black bg-opacity-75"
        onClick={handleClose}
        aria-hidden="true"
      />

      {/* Modal */}
      <div className="relative flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-4xl max-h-[90vh] bg-white rounded-lg shadow-2xl flex flex-col">
          {/* Header */}
          <div className={`flex-shrink-0 px-6 py-4 border-b ${borderColor} ${bgColor}`}>
            <div className="flex items-start justify-between">
              <div className="flex items-center space-x-3">
                <FileText className={`h-6 w-6 ${textColor}`} />
                <div>
                  <h2 className={`text-xl font-semibold ${textColor}`}>
                    {isRequired ? 'Agreement Acceptance Required' : 'Updated Agreement'}
                  </h2>
                  <p className={`text-sm ${textColor.replace('800', '700')}`}>
                    {isRequired 
                      ? 'You must accept the EarnLayer Publisher Agreement to continue using the platform.'
                      : 'Please review the updated EarnLayer Publisher Agreement.'
                    }
                  </p>
                </div>
              </div>
              
              {canClose && onClose && (
                <button
                  type="button"
                  onClick={handleClose}
                  disabled={isAccepting}
                  className={`rounded-md p-2 ${textColor} hover:bg-white hover:bg-opacity-50 focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50`}
                >
                  <span className="sr-only">Close</span>
                  <svg className="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                    <path fillRule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clipRule="evenodd" />
                  </svg>
                </button>
              )}
            </div>

            {/* Agreement Info */}
            <div className="mt-3 text-sm text-gray-600">
              <span className="font-medium">Version:</span> {agreement.version} • 
              <span className="font-medium ml-2">Effective:</span> {new Date(agreement.effectiveDate).toLocaleDateString()}
            </div>

            {/* Scroll Progress Indicator */}
            {isRequired && (
              <div className="mt-3">
                <div className="flex items-center space-x-2 text-sm">
                  {hasScrolledToBottom ? (
                    <>
                      <Check className="h-4 w-4 text-green-600" />
                      <span className="text-green-800 font-medium">You have read the full agreement</span>
                    </>
                  ) : (
                    <>
                      <AlertTriangle className="h-4 w-4 text-yellow-600" />
                      <span className="text-yellow-800">Please scroll to the bottom to read the full agreement</span>
                    </>
                  )}
                </div>
              </div>
            )}
          </div>

          {/* Content */}
          <div 
            ref={contentRef}
            className="flex-1 overflow-y-auto px-6 py-4"
            onScroll={handleScroll}
          >
            <div className="prose max-w-none">
              {agreement.content.split('\n').map((paragraph, index) => {
                if (paragraph.trim() === '') {
                  return <br key={index} />;
                }
                
                if (paragraph.startsWith('# ')) {
                  return (
                    <h1 key={index} className="text-2xl font-bold text-gray-900 mt-6 mb-4">
                      {paragraph.replace('# ', '')}
                    </h1>
                  );
                }
                
                if (paragraph.startsWith('## ')) {
                  return (
                    <h2 key={index} className="text-xl font-semibold text-gray-800 mt-5 mb-3">
                      {paragraph.replace('## ', '')}
                    </h2>
                  );
                }
                
                if (paragraph.startsWith('**') && paragraph.endsWith('**')) {
                  return (
                    <p key={index} className="font-semibold text-gray-900 mb-2">
                      {paragraph.replace(/\*\*/g, '')}
                    </p>
                  );
                }
                
                if (paragraph.startsWith('- ')) {
                  return (
                    <li key={index} className="ml-4 mb-1 text-gray-700">
                      {paragraph.replace('- ', '')}
                    </li>
                  );
                }
                
                if (paragraph.trim() === '---') {
                  return <hr key={index} className="my-6 border-gray-300" />;
                }
                
                return (
                  <p key={index} className="mb-3 text-gray-700 leading-relaxed">
                    {paragraph}
                  </p>
                );
              })}
            </div>

            {/* Bottom spacing to ensure scroll detection works */}
            <div className="h-4" />
          </div>

          {/* Footer */}
          <div className="flex-shrink-0 px-6 py-4 border-t border-gray-200 bg-gray-50">
            {error && (
              <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-md">
                <div className="flex">
                  <AlertTriangle className="h-5 w-5 text-red-400" />
                  <div className="ml-3">
                    <p className="text-sm text-red-800">{error}</p>
                  </div>
                </div>
              </div>
            )}

            <div className="flex justify-between items-center">
              <div className="text-sm text-gray-600">
                {isRequired ? (
                  <span>Acceptance is required to continue using the platform</span>
                ) : (
                  <span>Review the changes and accept to continue</span>
                )}
              </div>

              <div className="flex space-x-3">
                {canClose && onClose && (
                  <button
                    type="button"
                    onClick={handleClose}
                    disabled={isAccepting}
                    className="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-50"
                  >
                    Cancel
                  </button>
                )}

                <button
                  type="button"
                  onClick={handleAccept}
                  disabled={!canAccept || isAccepting}
                  className={`inline-flex items-center px-6 py-2 text-sm font-medium text-white rounded-md shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-50 disabled:cursor-not-allowed ${buttonColor}`}
                >
                  {isAccepting ? (
                    <>
                      <div className="mr-2 h-4 w-4 animate-spin rounded-full border-2 border-white border-t-transparent"></div>
                      Accepting...
                    </>
                  ) : (
                    <>
                      <Check className="mr-2 h-4 w-4" />
                      I Accept the Agreement
                    </>
                  )}
                </button>
              </div>
            </div>

            {isRequired && !hasScrolledToBottom && (
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
};