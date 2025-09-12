'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';

interface AgreementCheckboxProps {
  onAcceptanceChange: (accepted: boolean) => void;
  disabled?: boolean;
  className?: string;
  required?: boolean;
  agreementUrl?: string;
  agreementText?: string;
}

export const AgreementCheckbox: React.FC<AgreementCheckboxProps> = ({
  onAcceptanceChange,
  disabled = false,
  className = '',
  required = true,
  agreementUrl = '/agreement',
  agreementText = 'EarnLayer Publisher Agreement'
}) => {
  const [isChecked, setIsChecked] = useState(false);
  const [isLoading, setIsLoading] = useState(false);

  const handleChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const checked = e.target.checked;
    setIsChecked(checked);
    
    if (checked) {
      setIsLoading(true);
    }

    // Call the parent callback
    onAcceptanceChange(checked);
    
    if (checked) {
      // Add slight delay to show loading state
      setTimeout(() => setIsLoading(false), 200);
    }
  };

  const checkboxId = 'agreement-checkbox';

  return (
    <div className={`flex items-start space-x-3 ${className}`}>
      <div className="flex items-center h-5">
        <input
          id={checkboxId}
          name="agreement"
          type="checkbox"
          checked={isChecked}
          onChange={handleChange}
          disabled={disabled || isLoading}
          required={required}
          className="w-4 h-4 text-blue-600 border-gray-300 rounded focus:ring-blue-500 focus:ring-2 disabled:opacity-50 disabled:cursor-not-allowed"
          aria-describedby="agreement-description"
        />
      </div>
      <div className="text-sm">
        <label 
          htmlFor={checkboxId} 
          className={`font-medium text-gray-900 cursor-pointer select-none ${disabled ? 'opacity-50 cursor-not-allowed' : ''}`}
        >
          <span id="agreement-description">
            {required && <span className="text-red-500 mr-1">*</span>}
            I agree to the{' '}
            <Link 
              href={agreementUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="text-blue-600 hover:text-blue-800 hover:underline font-semibold"
              onClick={(e) => e.stopPropagation()}
            >
              {agreementText}
            </Link>
          </span>
        </label>
        {required && (
          <p className="text-xs text-gray-500 mt-1">
            You must accept the agreement to continue
          </p>
        )}
        {isLoading && (
          <p className="text-xs text-blue-600 mt-1 flex items-center">
            <svg className="animate-spin -ml-1 mr-2 h-3 w-3 text-blue-600" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            </svg>
            Processing...
          </p>
        )}
      </div>
    </div>
  );
};