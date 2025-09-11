import { NextRequest } from "next/server";
import { Pool } from "pg";

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 5,
});

interface LogEntry {
  id: string;
  timestamp: string;
  level: string;
  endpoint: string;
  method?: string;
  message: string;
  details?: any;
  requestId?: string;
  statusCode?: number;
  duration?: number;
  userId?: string;
}

let clientConnections = new Set<ReadableStreamDefaultController>();

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const level = searchParams.get('level') || 'all';
  const endpoint = searchParams.get('endpoint');
  
  const stream = new ReadableStream({
    start(controller) {
      clientConnections.add(controller);
      
      // Send initial connection message
      const connectMessage = `data: ${JSON.stringify({
        type: 'connected',
        message: 'Connected to log stream',
        timestamp: new Date().toISOString(),
      })}\n\n`;
      controller.enqueue(new TextEncoder().encode(connectMessage));

      // Send recent logs
      sendRecentLogs(controller, level, endpoint);

      // Set up periodic polling for new logs
      const pollInterval = setInterval(async () => {
        try {
          await sendNewLogs(controller, level, endpoint);
        } catch (error) {
          console.error('Error polling logs:', error);
        }
      }, 2000); // Poll every 2 seconds

      // Cleanup on disconnect
      request.signal.addEventListener('abort', () => {
        clearInterval(pollInterval);
        clientConnections.delete(controller);
        try {
          controller.close();
        } catch (e) {
          // Controller might already be closed
        }
      });
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET',
      'Access-Control-Allow-Headers': 'Cache-Control',
    },
  });
}

async function sendRecentLogs(
  controller: ReadableStreamDefaultController, 
  level: string, 
  endpoint?: string | null
) {
  try {
    let query = `
      SELECT id, timestamp, level, endpoint, method, message, details, 
             request_id, status_code, duration, user_id 
      FROM api_logs 
      WHERE 1=1
    `;
    const params: any[] = [];
    let paramIndex = 1;

    // Add level filter
    if (level !== 'all') {
      query += ` AND level = $${paramIndex}`;
      params.push(level);
      paramIndex++;
    }

    // Add endpoint filter
    if (endpoint) {
      query += ` AND endpoint ILIKE $${paramIndex}`;
      params.push(`%${endpoint}%`);
      paramIndex++;
    }

    query += ` ORDER BY timestamp DESC LIMIT 50`;

    const result = await pool.query(query, params);
    
    // Send logs in reverse order (oldest first for stream)
    const logs = result.rows.reverse();
    
    for (const row of logs) {
      const logEntry: LogEntry = {
        id: row.id.toString(),
        timestamp: row.timestamp,
        level: row.level,
        endpoint: row.endpoint,
        method: row.method,
        message: row.message,
        details: row.details,
        requestId: row.request_id,
        statusCode: row.status_code,
        duration: row.duration,
        userId: row.user_id,
      };

      const message = `data: ${JSON.stringify({
        type: 'log',
        ...logEntry,
      })}\n\n`;
      
      controller.enqueue(new TextEncoder().encode(message));
    }
  } catch (error) {
    console.error('Error fetching recent logs:', error);
    const errorMessage = `data: ${JSON.stringify({
      type: 'error',
      message: 'Failed to fetch recent logs',
      timestamp: new Date().toISOString(),
    })}\n\n`;
    controller.enqueue(new TextEncoder().encode(errorMessage));
  }
}

let lastLogId = 0;

async function sendNewLogs(
  controller: ReadableStreamDefaultController,
  level: string,
  endpoint?: string | null
) {
  try {
    let query = `
      SELECT id, timestamp, level, endpoint, method, message, details, 
             request_id, status_code, duration, user_id 
      FROM api_logs 
      WHERE id > $1
    `;
    const params: any[] = [lastLogId];
    let paramIndex = 2;

    // Add level filter
    if (level !== 'all') {
      query += ` AND level = $${paramIndex}`;
      params.push(level);
      paramIndex++;
    }

    // Add endpoint filter
    if (endpoint) {
      query += ` AND endpoint ILIKE $${paramIndex}`;
      params.push(`%${endpoint}%`);
      paramIndex++;
    }

    query += ` ORDER BY timestamp ASC`;

    const result = await pool.query(query, params);
    
    for (const row of result.rows) {
      lastLogId = Math.max(lastLogId, row.id);
      
      const logEntry: LogEntry = {
        id: row.id.toString(),
        timestamp: row.timestamp,
        level: row.level,
        endpoint: row.endpoint,
        method: row.method,
        message: row.message,
        details: row.details,
        requestId: row.request_id,
        statusCode: row.status_code,
        duration: row.duration,
        userId: row.user_id,
      };

      const message = `data: ${JSON.stringify({
        type: 'log',
        ...logEntry,
      })}\n\n`;
      
      controller.enqueue(new TextEncoder().encode(message));
    }
  } catch (error) {
    console.error('Error fetching new logs:', error);
  }
}