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