'use client';

import { useAgreementGuard } from '@/hooks/useAgreementGuard';
import { RequiredAgreementModal } from './RequiredAgreementModal';

interface AgreementGuardProps {
  children: React.ReactNode;
  enforceAgreement?: boolean;
}

/**
 * AgreementGuard component that ensures authenticated users have accepted
 * the current agreement before accessing the application.
 * 
 * This component should be wrapped around your main application content
 * in your root layout or _app component.
 */
export const AgreementGuard: React.FC<AgreementGuardProps> = ({ 
  children, 
  enforceAgreement = true 
}) => {
  const {
    currentVersion,
    showModal,
    needsAcceptance,
    acceptAgreement,
    loading,
    error,
    session,
  } = useAgreementGuard();

  // Don't show agreement modal if enforcement is disabled
  const shouldShowModal = enforceAgreement && showModal;

  // If there's an error loading agreement data and user is authenticated,
  // show a more user-friendly error state
  if (error && session?.user) {
    return (
      <div className="min-h-screen bg-gray-50 flex flex-col justify-center py-12 sm:px-6 lg:px-8">
        <div className="mt-8 sm:mx-auto sm:w-full sm:max-w-md">
          <div className="bg-white py-8 px-4 shadow sm:rounded-lg sm:px-10">
            <div className="text-center">
              <div className="mx-auto flex items-center justify-center h-12 w-12 rounded-full bg-red-100">
                <svg
                  className="h-6 w-6 text-red-600"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.5 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
                  />
                </svg>
              </div>
              <h3 className="mt-2 text-sm font-medium text-gray-900">
                Agreement System Error
              </h3>
              <p className="mt-1 text-sm text-gray-500">
                {error}
              </p>
              <div className="mt-6">
                <button
                  type="button"
                  onClick={() => window.location.reload()}
                  className="inline-flex items-center px-4 py-2 border border-transparent shadow-sm text-sm font-medium rounded-md text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
                >
                  Reload Page
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <>
      {/* Main application content */}
      {children}

      {/* Agreement Modal */}
      {shouldShowModal && (
        <RequiredAgreementModal
          isOpen={shouldShowModal}
          agreement={currentVersion}
          onAccept={acceptAgreement}
          canClose={false} // Required acceptance - cannot be closed
          type="required"
        />
      )}
    </>
  );
};