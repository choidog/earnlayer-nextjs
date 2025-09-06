import { NextRequest } from "next/server";
import crypto from "crypto";

// Log levels
export enum LogLevel {
  ERROR = "error",
  WARN = "warn",
  INFO = "info", 
  DEBUG = "debug"
}

// Context interface for structured logging
export interface LogContext {
  requestId?: string;
  endpoint?: string;
  method?: string;
  userId?: string;
  userEmail?: string;
  timestamp?: string;
  duration?: number;
  [key: string]: any;
}

// Log entry structure
export interface LogEntry {
  level: LogLevel;
  message: string;
  context: LogContext;
  error?: Error;
  data?: any;
}

class Logger {
  private context: LogContext = {};

  // Set global context for the logger instance
  setContext(context: Partial<LogContext>): Logger {
    const newLogger = new Logger();
    newLogger.context = { ...this.context, ...context };
    return newLogger;
  }

  // Generate a unique request ID
  static generateRequestId(): string {
    return crypto.randomBytes(8).toString('hex');
  }

  // Create context from NextJS request
  static fromRequest(request: NextRequest, additionalContext: Partial<LogContext> = {}): Logger {
    const requestId = Logger.generateRequestId();
    const url = new URL(request.url);
    
    const context: LogContext = {
      requestId,
      endpoint: url.pathname,
      method: request.method,
      timestamp: new Date().toISOString(),
      ...additionalContext
    };

    return new Logger().setContext(context);
  }

  private log(level: LogLevel, message: string, data?: any, error?: Error): void {
    const entry: LogEntry = {
      level,
      message,
      context: {
        ...this.context,
        timestamp: this.context.timestamp || new Date().toISOString()
      },
      ...(data && { data }),
      ...(error && { error })
    };

    // Console output with emoji prefixes
    const emoji = {
      [LogLevel.ERROR]: "❌",
      [LogLevel.WARN]: "⚠️ ",
      [LogLevel.INFO]: "📋",
      [LogLevel.DEBUG]: "🔍"
    };

    const prefix = `${emoji[level]} [${this.context.endpoint || 'API'}]`;
    
    if (level === LogLevel.ERROR && error) {
      console.error(`${prefix} ${message}`, {
        context: entry.context,
        error: {
          name: error.name,
          message: error.message,
          stack: error.stack
        },
        ...(data && { data })
      });
    } else {
      console.log(`${prefix} ${message}`, {
        context: entry.context,
        ...(data && { data })
      });
    }
  }

  // Public logging methods
  error(message: string, error?: Error, data?: any): void {
    this.log(LogLevel.ERROR, message, data, error);
  }

  warn(message: string, data?: any): void {
    this.log(LogLevel.WARN, message, data);
  }

  info(message: string, data?: any): void {
    this.log(LogLevel.INFO, message, data);
  }

  debug(message: string, data?: any): void {
    this.log(LogLevel.DEBUG, message, data);
  }

  // Specialized logging methods
  requestStart(body?: any): void {
    this.info("Request started", {
      body: body ? JSON.stringify(body, null, 2) : null
    });
  }

  requestEnd(statusCode: number, duration?: number): void {
    this.info(`Request completed`, {
      statusCode,
      ...(duration && { duration: `${duration}ms` })
    });
  }

  validationError(message: string, details: any): void {
    this.error(`Validation failed: ${message}`, undefined, { validation: details });
  }

  authError(message: string, details?: any): void {
    this.error(`Authentication error: ${message}`, undefined, details);
  }

  databaseError(operation: string, error: Error, query?: string): void {
    this.error(`Database ${operation} failed`, error, { query });
  }

  // Create a timer for measuring operation duration
  timer(): { end: () => number } {
    const start = Date.now();
    return {
      end: () => Date.now() - start
    };
  }

  // Child logger with additional context
  child(additionalContext: Partial<LogContext>): Logger {
    return this.setContext(additionalContext);
  }
}

// Export a default logger instance
export const logger = new Logger();

// Export the Logger class for creating instances
export { Logger };