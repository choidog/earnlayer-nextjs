import { z } from "zod";

// Base error interface
export interface BaseError {
  code: string;
  message: string;
  details?: Record<string, any>;
  statusCode: number;
}

// Error categories
export enum ErrorCategory {
  VALIDATION = "VALIDATION",
  AUTHENTICATION = "AUTHENTICATION", 
  AUTHORIZATION = "AUTHORIZATION",
  NOT_FOUND = "NOT_FOUND",
  DATABASE = "DATABASE",
  EXTERNAL_API = "EXTERNAL_API",
  BUSINESS_LOGIC = "BUSINESS_LOGIC",
  INTERNAL = "INTERNAL"
}

// Specific error types
export class ValidationError extends Error implements BaseError {
  code: string;
  statusCode: number = 400;
  details: Record<string, any>;

  constructor(
    message: string,
    details: Record<string, any> = {},
    code: string = "VALIDATION_FAILED"
  ) {
    super(message);
    this.name = "ValidationError";
    this.code = code;
    this.details = details;
  }

  static fromZod(error: z.ZodError, schema?: Record<string, any>): ValidationError {
    return new ValidationError(
      "The request body contains invalid or missing fields",
      {
        validation_errors: error.errors,
        expected_schema: schema,
        field_issues: error.errors.map(err => ({
          field: err.path.join('.'),
          issue: err.message,
          received: err.received
        }))
      },
      "VALIDATION_SCHEMA_ERROR"
    );
  }
}

export class AuthenticationError extends Error implements BaseError {
  code: string;
  statusCode: number = 401;
  details: Record<string, any>;

  constructor(
    message: string = "Authentication required",
    details: Record<string, any> = {},
    code: string = "AUTHENTICATION_REQUIRED"
  ) {
    super(message);
    this.name = "AuthenticationError";
    this.code = code;
    this.details = details;
  }

  static apiKeyRequired(): AuthenticationError {
    return new AuthenticationError(
      "API key is required to access this endpoint",
      {
        required_headers: ["Authorization: Bearer <api_key>", "X-API-Key: <api_key>"],
        documentation: "https://docs.earnlayerai.com/api/authentication",
        help: "Generate an API key in your dashboard at https://app.earnlayerai.com/dashboard/api-keys"
      },
      "API_KEY_REQUIRED"
    );
  }

  static apiKeyInvalid(): AuthenticationError {
    return new AuthenticationError(
      "The provided API key is invalid or expired",
      {
        possible_causes: [
          "API key was revoked or deleted",
          "API key has expired",
          "API key format is incorrect",
          "API key was regenerated"
        ],
        next_steps: [
          "Check your API key in the dashboard",
          "Generate a new API key if needed",
          "Ensure the key is properly formatted"
        ],
        documentation: "https://docs.earnlayerai.com/api/authentication"
      },
      "API_KEY_INVALID"
    );
  }

  static apiKeyExpired(expirationDate?: Date): AuthenticationError {
    return new AuthenticationError(
      "The provided API key has expired",
      {
        expired_at: expirationDate?.toISOString(),
        next_steps: [
          "Generate a new API key in your dashboard",
          "Update your application with the new key"
        ],
        help: "Visit https://app.earnlayerai.com/dashboard/api-keys to manage your keys"
      },
      "API_KEY_EXPIRED"
    );
  }
}

export class AuthorizationError extends Error implements BaseError {
  code: string;
  statusCode: number = 403;
  details: Record<string, any>;

  constructor(
    message: string = "Insufficient permissions",
    details: Record<string, any> = {},
    code: string = "AUTHORIZATION_FAILED"
  ) {
    super(message);
    this.name = "AuthorizationError";
    this.code = code;
    this.details = details;
  }

  static insufficientPermissions(requiredPermission: string, availablePermissions: string[] = []): AuthorizationError {
    return new AuthorizationError(
      `Your API key lacks the required permission: ${requiredPermission}`,
      {
        required_permission: requiredPermission,
        available_permissions: availablePermissions,
        common_permissions: {
          "ads:serve": "Serve and display advertisements",
          "mcp:access": "Access MCP server functionality",
          "chat:access": "Access chat and conversation APIs",
          "analytics:read": "Read analytics and metrics data",
          "admin:*": "Full administrative access"
        },
        next_steps: [
          "Contact your administrator to request permission",
          "Generate a new API key with proper permissions",
          "Check your API key configuration in the dashboard"
        ],
        help: "Visit https://app.earnlayerai.com/dashboard/api-keys to manage permissions"
      },
      "INSUFFICIENT_PERMISSIONS"
    );
  }

  static resourceAccessDenied(resourceType: string, resourceId?: string): AuthorizationError {
    return new AuthorizationError(
      `Access denied: You can only access your own ${resourceType}`,
      {
        resource_type: resourceType,
        resource_id: resourceId,
        explanation: "API keys can only access resources owned by the associated user account",
        security_note: "This restriction prevents unauthorized access to other users' data",
        next_steps: [
          `Ensure you're accessing your own ${resourceType}`,
          "Verify the resource ID belongs to your account",
          "Contact support if you believe this is an error"
        ]
      },
      "RESOURCE_ACCESS_DENIED"
    );
  }
}

export class NotFoundError extends Error implements BaseError {
  code: string;
  statusCode: number = 404;
  details: Record<string, any>;

  constructor(
    message: string,
    details: Record<string, any> = {},
    code: string = "RESOURCE_NOT_FOUND"
  ) {
    super(message);
    this.name = "NotFoundError";
    this.code = code;
    this.details = details;
  }
}

export class DatabaseError extends Error implements BaseError {
  code: string;
  statusCode: number = 500;
  details: Record<string, any>;

  constructor(
    message: string,
    details: Record<string, any> = {},
    code: string = "DATABASE_ERROR"
  ) {
    super(message);
    this.name = "DatabaseError";
    this.code = code;
    this.details = details;
  }
}

export class BusinessLogicError extends Error implements BaseError {
  code: string;
  statusCode: number = 400;
  details: Record<string, any>;

  constructor(
    message: string,
    details: Record<string, any> = {},
    code: string = "BUSINESS_LOGIC_ERROR"
  ) {
    super(message);
    this.name = "BusinessLogicError";
    this.code = code;
    this.details = details;
  }
}

export class RateLimitError extends Error implements BaseError {
  code: string;
  statusCode: number = 429;
  details: Record<string, any>;

  constructor(
    message: string = "Rate limit exceeded",
    details: Record<string, any> = {},
    code: string = "RATE_LIMIT_EXCEEDED"
  ) {
    super(message);
    this.name = "RateLimitError";
    this.code = code;
    this.details = details;
  }

  static exceeded(
    limit: number,
    windowMs: number,
    resetTime?: number,
    remaining: number = 0
  ): RateLimitError {
    const resetDate = resetTime ? new Date(resetTime) : null;
    const windowHours = Math.round(windowMs / (1000 * 60 * 60));
    
    return new RateLimitError(
      `Rate limit exceeded: ${limit} requests per ${windowHours} hour(s)`,
      {
        rate_limit: {
          limit,
          remaining,
          window_ms: windowMs,
          window_description: `${windowHours} hour${windowHours !== 1 ? 's' : ''}`,
          reset_time: resetDate?.toISOString(),
          reset_time_human: resetDate?.toLocaleString()
        },
        upgrade_options: {
          free_tier: "10 requests per day",
          pro_tier: "10,000 requests per day",
          enterprise: "Custom limits available"
        },
        next_steps: [
          resetDate ? `Wait until ${resetDate.toLocaleString()} for limit reset` : "Wait for rate limit to reset",
          "Upgrade your plan for higher limits",
          "Optimize your request patterns to stay within limits"
        ],
        help: "Visit https://app.earnlayerai.com/dashboard/billing to upgrade your plan"
      },
      "RATE_LIMIT_EXCEEDED"
    );
  }
}

export class InternalError extends Error implements BaseError {
  code: string;
  statusCode: number = 500;
  details: Record<string, any>;

  constructor(
    message: string = "Internal server error",
    details: Record<string, any> = {},
    code: string = "INTERNAL_ERROR"
  ) {
    super(message);
    this.name = "InternalError";
    this.code = code;
    this.details = details;
  }
}

// Type guard functions
export function isAPIError(error: any): error is BaseError {
  return error && typeof error.code === 'string' && typeof error.statusCode === 'number';
}

export function getErrorCategory(error: BaseError): ErrorCategory {
  if (error.code.startsWith('VALIDATION')) return ErrorCategory.VALIDATION;
  if (error.code.startsWith('AUTH')) return ErrorCategory.AUTHENTICATION;
  if (error.code.startsWith('AUTHORIZATION')) return ErrorCategory.AUTHORIZATION;
  if (error.code.includes('NOT_FOUND')) return ErrorCategory.NOT_FOUND;
  if (error.code.includes('DATABASE')) return ErrorCategory.DATABASE;
  if (error.code.includes('EXTERNAL')) return ErrorCategory.EXTERNAL_API;
  if (error.code.includes('BUSINESS')) return ErrorCategory.BUSINESS_LOGIC;
  return ErrorCategory.INTERNAL;
}