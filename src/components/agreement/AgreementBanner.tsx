'use client';

import { useState } from 'react';
import { X, FileText, Check } from 'lucide-react';

interface AgreementVersion {
  id: string;
  version: string;
  effectiveDate: string;
}

interface AgreementBannerProps {
  version: AgreementVersion;
  onAccept: () => Promise<void>;
  onDismiss: () => Promise<void>;
  onViewAgreement: () => void;
  className?: string;
  type?: 'update' | 'required';
}

export const AgreementBanner: React.FC<AgreementBannerProps> = ({
  version,
  onAccept,
  onDismiss,
  onViewAgreement,
  className = '',
  type = 'update'
}) => {
  const [isAccepting, setIsAccepting] = useState(false);
  const [isDismissing, setIsDismissing] = useState(false);
  const [isVisible, setIsVisible] = useState(true);

  const handleAccept = async () => {
    if (isAccepting || isDismissing) return;
    
    setIsAccepting(true);
    try {
      await onAccept();
      setIsVisible(false);
    } catch (error) {
      console.error('Failed to accept agreement:', error);
      // Keep banner visible on error
    } finally {
      setIsAccepting(false);
    }
  };

  const handleDismiss = async () => {
    if (isAccepting || isDismissing) return;

    setIsDismissing(true);
    try {
      await onDismiss();
      setIsVisible(false);
    } catch (error) {
      console.error('Failed to dismiss banner:', error);
      // Keep banner visible on error
    } finally {
      setIsDismissing(false);
    }
  };

  if (!isVisible) {
    return null;
  }

  const isRequired = type === 'required';
  const bgColor = isRequired ? 'bg-red-50 border-red-200' : 'bg-blue-50 border-blue-200';
  const textColor = isRequired ? 'text-red-800' : 'text-blue-800';
  const buttonColor = isRequired ? 'bg-red-600 hover:bg-red-700' : 'bg-blue-600 hover:bg-blue-700';

  return (
    <div className={`border-l-4 ${bgColor} p-4 ${className}`} role="alert">
      <div className="flex items-start">
        <div className="flex-shrink-0">
          <FileText className={`h-5 w-5 ${textColor}`} aria-hidden="true" />
        </div>
        <div className="ml-3 flex-1">
          <div className="flex items-center justify-between">
            <div>
              <h3 className={`text-sm font-medium ${textColor}`}>
                {isRequired ? 'Agreement Acceptance Required' : 'Agreement Updated'}
              </h3>
              <div className={`mt-2 text-sm ${textColor.replace('800', '700')}`}>
                <p>
                  {isRequired 
                    ? 'You must accept the current EarnLayer Publisher Agreement to continue using the platform.'
                    : `A new version (${version.version}) of the EarnLayer Publisher Agreement is available.`
                  }
                </p>
                <p className="mt-1">
                  Effective Date: {new Date(version.effectiveDate).toLocaleDateString()}
                </p>
              </div>
            </div>
            {!isRequired && (
              <button
                type="button"
                onClick={handleDismiss}
                disabled={isDismissing}
                className={`ml-4 flex-shrink-0 rounded-md bg-transparent p-1.5 ${textColor} hover:bg-blue-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-50`}
                aria-label="Dismiss banner"
              >
                {isDismissing ? (
                  <div className="h-4 w-4 animate-spin rounded-full border-2 border-current border-t-transparent"></div>
                ) : (
                  <X className="h-4 w-4" />
                )}
              </button>
            )}
          </div>
          
          <div className="mt-4 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={handleAccept}
              disabled={isAccepting || isDismissing}
              className={`inline-flex items-center rounded-md ${buttonColor} px-3 py-2 text-sm font-medium text-white shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-50 disabled:cursor-not-allowed`}
            >
              {isAccepting ? (
                <>
                  <div className="mr-2 h-4 w-4 animate-spin rounded-full border-2 border-white border-t-transparent"></div>
                  Accepting...
                </>
              ) : (
                <>
                  <Check className="mr-2 h-4 w-4" />
                  Accept Agreement
                </>
              )}
            </button>
            
            <button
              type="button"
              onClick={onViewAgreement}
              className={`inline-flex items-center rounded-md bg-white px-3 py-2 text-sm font-medium ${textColor} shadow-sm ring-1 ring-inset ${textColor.replace('text-', 'ring-').replace('800', '300')} hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2`}
            >
              <FileText className="mr-2 h-4 w-4" />
              View Agreement
            </button>
            
            {!isRequired && (
              <button
                type="button"
                onClick={handleDismiss}
                disabled={isDismissing}
                className="inline-flex items-center rounded-md bg-white px-3 py-2 text-sm font-medium text-gray-700 shadow-sm ring-1 ring-inset ring-gray-300 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-50"
              >
                {isDismissing ? (
                  <>
                    <div className="mr-2 h-4 w-4 animate-spin rounded-full border-2 border-gray-700 border-t-transparent"></div>
                    Dismissing...
                  </>
                ) : (
                  'Dismiss'
                )}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};