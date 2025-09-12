import pino from 'pino';
import { Pool } from 'pg';
import { NextRequest } from 'next/server';
import crypto from 'crypto';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 5,
});

interface LogEntry {
  level: string;
  endpoint: string;
  method?: string;
  message: string;
  details?: any;
  requestId?: string;
  statusCode?: number;
  duration?: number;
  userId?: string;
  ipAddress?: string;
  userAgent?: string;
}

class DatabaseTransport {
  private buffer: LogEntry[] = [];
  private batchTimeout: NodeJS.Timeout | null = null;
  private readonly BATCH_SIZE = 10;
  private readonly BATCH_TIMEOUT = 1000;

  write(log: LogEntry) {
    this.buffer.push(log);
    
    if (this.buffer.length >= this.BATCH_SIZE) {
      this.flush();
    } else if (!this.batchTimeout) {
      this.batchTimeout = setTimeout(() => this.flush(), this.BATCH_TIMEOUT);
    }
  }

  private async flush() {
    if (this.buffer.length === 0) return;
    
    const logsToWrite = [...this.buffer];
    this.buffer = [];
    
    if (this.batchTimeout) {
      clearTimeout(this.batchTimeout);
      this.batchTimeout = null;
    }

    try {
      const values = logsToWrite.map(log => [
        log.level,
        log.endpoint,
        log.method,
        log.message,
        log.details ? JSON.stringify(log.details) : null,
        log.requestId,
        log.statusCode,
        log.duration,
        log.userId,
        log.ipAddress,
        log.userAgent
      ]);

      const query = `
        INSERT INTO api_logs (
          level, endpoint, method, message, details, 
          request_id, status_code, duration, user_id, ip_address, user_agent
        ) VALUES ${values.map((_, i) => 
          `($${i * 11 + 1}, $${i * 11 + 2}, $${i * 11 + 3}, $${i * 11 + 4}, $${i * 11 + 5}, $${i * 11 + 6}, $${i * 11 + 7}, $${i * 11 + 8}, $${i * 11 + 9}, $${i * 11 + 10}, $${i * 11 + 11})`
        ).join(', ')}
      `;

      await pool.query(query, values.flat());
    } catch (error) {
      console.error('Failed to write logs to database:', error);
      // Fallback to console logging
      logsToWrite.forEach(log => {
        console.log(`[${log.level.toUpperCase()}] ${log.endpoint}: ${log.message}`);
      });
    }
  }
}

const dbTransport = new DatabaseTransport();

const logger = pino({
  level: process.env.NODE_ENV === 'production' ? 'info' : 'debug',
  formatters: {
    level: (label) => ({ level: label }),
  },
  timestamp: pino.stdTimeFunctions.isoTime,
}, {
  write: (chunk: string) => {
    try {
      const log = JSON.parse(chunk);
      const logEntry: LogEntry = {
        level: log.level,
        endpoint: log.endpoint || 'unknown',
        method: log.method,
        message: log.msg || log.message || 'No message',
        details: log.details,
        requestId: log.requestId,
        statusCode: log.statusCode,
        duration: log.duration,
        userId: log.userId,
        ipAddress: log.ipAddress,
        userAgent: log.userAgent,
      };
      
      dbTransport.write(logEntry);
      
      // Also log to console in development
      if (process.env.NODE_ENV !== 'production') {
        console.log(chunk);
      }
    } catch (error) {
      console.error('Failed to parse log:', error);
    }
  }
});

// Logger class for structured API logging
export class Logger {
  public context: {
    requestId: string;
    endpoint: string;
    method?: string;
    userId?: string;
    userEmail?: string;
    ipAddress?: string;
    userAgent?: string;
  };

  private constructor(context: { 
    requestId: string; 
    endpoint: string;
    method?: string;
    ipAddress?: string;
    userAgent?: string;
  }) {
    this.context = context;
  }

  static fromRequest(request: NextRequest, options?: { endpoint?: string }): Logger {
    const requestId = crypto.randomUUID();
    const endpoint = options?.endpoint || new URL(request.url).pathname;
    const method = request.method;
    const ipAddress = request.headers.get('x-forwarded-for') || 
                     request.headers.get('x-real-ip') || 
                     'unknown';
    const userAgent = request.headers.get('user-agent') || 'unknown';
    
    return new Logger({ 
      requestId, 
      endpoint, 
      method,
      ipAddress,
      userAgent
    });
  }

  info(message: string, data?: any) {
    logger.info({
      ...this.context,
      message,
      details: data,
    });
  }

  error(message: string, error: any, data?: any) {
    const errorMessage = error instanceof Error ? error.message : error.toString();
    const stack = error instanceof Error ? error.stack : undefined;
    
    logger.error({
      ...this.context,
      message,
      details: {
        error: errorMessage,
        stack: stack?.split('\n').slice(0, 5).join('\n'),
        ...data
      },
    });
  }

  warn(message: string, data?: any) {
    logger.warn({
      ...this.context,
      message,
      details: data,
    });
  }

  requestStart(body: any) {
    this.info(`🔄 Request started: ${this.context.method} ${this.context.endpoint}`, {
      body: typeof body === 'object' ? body : null,
      requestStart: true
    });
  }

  setContext(data: { userId?: string; userEmail?: string; [key: string]: any }) {
    this.context = { ...this.context, ...data };
  }

  databaseError(operation: string, error: Error) {
    this.error(`💾 Database error during ${operation}`, error, {
      operation,
      databaseError: true
    });
  }
}

export { logger };

// Helper functions for structured logging
export const logApiRequest = (data: {
  endpoint: string;
  method: string;
  requestId: string;
  userId?: string;
  ipAddress?: string;
  userAgent?: string;
}) => {
  logger.info({
    ...data,
    message: `🔄 [Request] ${data.method} ${data.endpoint}`,
  });
};

export const logApiResponse = (data: {
  endpoint: string;
  method: string;
  requestId: string;
  statusCode: number;
  duration: number;
  userId?: string;
}) => {
  const level = data.statusCode >= 500 ? 'error' : data.statusCode >= 400 ? 'warn' : 'info';
  const emoji = data.statusCode >= 500 ? '❌' : data.statusCode >= 400 ? '⚠️' : '✅';
  
  logger[level]({
    ...data,
    message: `${emoji} [Response] ${data.statusCode} - ${data.duration}ms`,
  });
};

export const logApiKeyValidation = (data: {
  endpoint: string;
  requestId: string;
  success: boolean;
  reason?: string;
  userId?: string;
  ipAddress?: string;
}) => {
  const level = data.success ? 'info' : 'warn';
  const emoji = data.success ? '🔑' : '🚫';
  const message = data.success 
    ? `${emoji} [API Key] Validation successful`
    : `${emoji} [API Key] Validation failed: ${data.reason}`;
  
  logger[level]({
    ...data,
    message,
    details: data.reason ? { reason: data.reason } : undefined,
  });
};

export const logError = (data: {
  endpoint: string;
  requestId: string;
  error: Error | string;
  userId?: string;
  statusCode?: number;
}) => {
  const errorMessage = data.error instanceof Error ? data.error.message : data.error;
  const stack = data.error instanceof Error ? data.error.stack : undefined;
  
  logger.error({
    ...data,
    message: `💥 [Error] ${errorMessage}`,
    details: { 
      error: errorMessage,
      stack: stack?.split('\n').slice(0, 5).join('\n') // Limit stack trace
    },
  });
};