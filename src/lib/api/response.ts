import { NextResponse } from "next/server";
import { z } from "zod";
import { BaseError, ValidationError, isAPIError } from "./errors";
import { Logger } from "@/lib/logging/logger";

// Standard API response format
export interface APIResponse<T = any> {
  success: boolean;
  data?: T;
  error?: {
    code: string;
    message: string;
    details?: Record<string, any>;
  };
  meta?: {
    timestamp: string;
    requestId?: string;
    version?: string;
  };
}

// Success response builder
export function successResponse<T>(
  data: T,
  meta: Partial<APIResponse["meta"]> = {}
): NextResponse<APIResponse<T>> {
  const response: APIResponse<T> = {
    success: true,
    data,
    meta: {
      timestamp: new Date().toISOString(),
      ...meta
    }
  };

  return NextResponse.json(response);
}

// Error response builder
export function errorResponse(
  error: BaseError | Error,
  requestId?: string
): NextResponse<APIResponse> {
  let apiError: BaseError;

  // Convert generic errors to structured errors
  if (!isAPIError(error)) {
    apiError = {
      code: "INTERNAL_ERROR",
      message: error.message || "An unexpected error occurred",
      statusCode: 500,
      details: {}
    };
  } else {
    apiError = error;
  }

  const response: APIResponse = {
    success: false,
    error: {
      code: apiError.code,
      message: apiError.message,
      details: apiError.details
    },
    meta: {
      timestamp: new Date().toISOString(),
      ...(requestId && { requestId })
    }
  };

  return NextResponse.json(response, { status: apiError.statusCode });
}

// Schema documentation generator
export interface SchemaField {
  type: string;
  required: boolean;
  description?: string;
  example?: any;
}

export function generateSchemaDoc(schema: z.ZodSchema): Record<string, SchemaField> {
  const shape = (schema as any)._def?.shape || {};
  const docs: Record<string, SchemaField> = {};

  for (const [key, fieldSchema] of Object.entries(shape)) {
    const field = fieldSchema as any;
    const isOptional = field._def?.typeName === "ZodOptional" || field.isOptional?.();
    
    docs[key] = {
      type: getZodTypeName(field),
      required: !isOptional,
      description: getFieldDescription(key, field),
      example: getFieldExample(key, field)
    };
  }

  return docs;
}

function getZodTypeName(schema: any): string {
  const typeName = schema._def?.typeName;
  if (!typeName) return "unknown";

  const typeMap: Record<string, string> = {
    ZodString: "string",
    ZodNumber: "number", 
    ZodBoolean: "boolean",
    ZodArray: "array",
    ZodObject: "object",
    ZodOptional: getZodTypeName(schema._def?.innerType),
    ZodUuid: "string (UUID format)",
    ZodEmail: "string (email format)"
  };

  return typeMap[typeName] || typeName.replace("Zod", "").toLowerCase();
}

function getFieldDescription(key: string, schema: any): string {
  // Generate smart descriptions based on field names
  const descriptions: Record<string, string> = {
    user_id: "Unique identifier for the user",
    user_email: "User's email address for notifications and identification",
    user_name: "Display name for the user",
    creator_id: "Unique identifier for the creator profile",
    session_id: "Session identifier for tracking conversation state",
    visitor_uuid: "Anonymous visitor tracking identifier", 
    ad_preferences: "User preferences for ad targeting and display",
    context: "Additional context information for the request",
    metadata: "Additional metadata for the request"
  };

  return descriptions[key] || `${key.replace(/_/g, " ")} field`;
}

function getFieldExample(key: string, schema: any): any {
  const examples: Record<string, any> = {
    user_id: "wbxHQnUV3xlo2AeTDnryKar0NZ6zPX9C",
    user_email: "user@example.com",
    user_name: "John Doe",
    creator_id: "550e8400-e29b-41d4-a716-446655440000",
    session_id: "session_123456789",
    visitor_uuid: "visitor_abcdef123",
    ad_preferences: { "categories": ["tech", "business"] },
    context: "Chat conversation initialization",
    metadata: { "source": "web_app", "version": "1.0" }
  };

  const type = getZodTypeName(schema);
  
  if (examples[key]) return examples[key];
  if (type.includes("email")) return "user@example.com";
  if (type.includes("UUID")) return "550e8400-e29b-41d4-a716-446655440000";
  if (type === "string") return `example_${key}`;
  if (type === "number") return 42;
  if (type === "boolean") return true;
  if (type === "array") return [];
  if (type === "object") return {};
  
  return null;
}

// Validation error with schema documentation
export function validationErrorWithSchema(
  zodError: z.ZodError,
  schema: z.ZodSchema,
  logger?: Logger
): ValidationError {
  const schemaDoc = generateSchemaDoc(schema);
  
  // Generate example request based on schema
  const exampleRequest: Record<string, any> = {};
  Object.entries(schemaDoc).forEach(([key, field]) => {
    if (field.required && field.example !== null) {
      exampleRequest[key] = field.example;
    }
  });

  const error = new ValidationError(
    "The request body contains invalid or missing fields",
    {
      validation_errors: zodError.errors,
      schema_documentation: schemaDoc,
      field_summary: {
        required_fields: Object.entries(schemaDoc)
          .filter(([_, field]) => field.required)
          .map(([key, _]) => key),
        optional_fields: Object.entries(schemaDoc)
          .filter(([_, field]) => !field.required)
          .map(([key, _]) => key)
      },
      example_request: exampleRequest
    },
    "VALIDATION_SCHEMA_ERROR"
  );

  if (logger) {
    logger.validationError("Schema validation failed", {
      errors: zodError.errors,
      schema: Object.keys(schemaDoc)
    });
  }

  return error;
}

// Error handler wrapper for API routes
export function withErrorHandler(
  handler: (request: any, context?: any) => Promise<NextResponse>,
  logger?: Logger
) {
  return async (request: any, context?: any): Promise<NextResponse> => {
    const startTime = Date.now();
    const requestLogger = logger || Logger.fromRequest(request);

    try {
      requestLogger.requestStart(await request.json().catch(() => null));
      
      const response = await handler(request, context);
      
      const duration = Date.now() - startTime;
      requestLogger.requestEnd(response.status, duration);
      
      return response;
    } catch (error) {
      const duration = Date.now() - startTime;
      
      if (isAPIError(error)) {
        requestLogger.error(`API Error: ${error.message}`, error, {
          code: error.code,
          duration: `${duration}ms`
        });
        return errorResponse(error, requestLogger.context.requestId);
      } else {
        requestLogger.error("Unexpected error in API handler", error as Error, {
          duration: `${duration}ms`
        });
        return errorResponse(error as Error, requestLogger.context.requestId);
      }
    }
  };
}