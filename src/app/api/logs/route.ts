import { NextRequest, NextResponse } from "next/server";
import { Pool } from "pg";

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 5,
});

export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    
    // Parse query parameters
    const level = searchParams.get('level') || 'all';
    const endpoint = searchParams.get('endpoint');
    const search = searchParams.get('search');
    const limit = Math.min(parseInt(searchParams.get('limit') || '100'), 1000);
    const offset = parseInt(searchParams.get('offset') || '0');
    const startDate = searchParams.get('startDate');
    const endDate = searchParams.get('endDate');

    // Build query
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

    // Add search filter
    if (search) {
      query += ` AND (message ILIKE $${paramIndex} OR endpoint ILIKE $${paramIndex})`;
      params.push(`%${search}%`);
      paramIndex++;
    }

    // Add date range filter
    if (startDate) {
      query += ` AND timestamp >= $${paramIndex}`;
      params.push(startDate);
      paramIndex++;
    }

    if (endDate) {
      query += ` AND timestamp <= $${paramIndex}`;
      params.push(endDate);
      paramIndex++;
    }

    // Add ordering and pagination
    query += ` ORDER BY timestamp DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
    params.push(limit, offset);

    // Execute query
    const result = await pool.query(query, params);

    // Get total count for pagination
    let countQuery = `
      SELECT COUNT(*) as total 
      FROM api_logs 
      WHERE 1=1
    `;
    const countParams: any[] = [];
    let countParamIndex = 1;

    // Apply same filters for count
    if (level !== 'all') {
      countQuery += ` AND level = $${countParamIndex}`;
      countParams.push(level);
      countParamIndex++;
    }

    if (endpoint) {
      countQuery += ` AND endpoint ILIKE $${countParamIndex}`;
      countParams.push(`%${endpoint}%`);
      countParamIndex++;
    }

    if (search) {
      countQuery += ` AND (message ILIKE $${countParamIndex} OR endpoint ILIKE $${countParamIndex})`;
      countParams.push(`%${search}%`);
      countParamIndex++;
    }

    if (startDate) {
      countQuery += ` AND timestamp >= $${countParamIndex}`;
      countParams.push(startDate);
      countParamIndex++;
    }

    if (endDate) {
      countQuery += ` AND timestamp <= $${countParamIndex}`;
      countParams.push(endDate);
      countParamIndex++;
    }

    const countResult = await pool.query(countQuery, countParams);
    const total = parseInt(countResult.rows[0].total);

    // Format response
    const logs = result.rows.map(row => ({
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
    }));

    return NextResponse.json({
      success: true,
      data: {
        logs,
        pagination: {
          limit,
          offset,
          total,
          hasMore: offset + limit < total,
        },
      },
    });

  } catch (error) {
    console.error('Error fetching logs:', error);
    return NextResponse.json(
      {
        success: false,
        error: 'Failed to fetch logs',
        details: error instanceof Error ? error.message : 'Unknown error',
      },
      { status: 500 }
    );
  }
}

export async function DELETE(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const olderThan = searchParams.get('olderThan'); // ISO date string
    const level = searchParams.get('level');

    let query = 'DELETE FROM api_logs WHERE 1=1';
    const params: any[] = [];
    let paramIndex = 1;

    if (olderThan) {
      query += ` AND timestamp < $${paramIndex}`;
      params.push(olderThan);
      paramIndex++;
    }

    if (level) {
      query += ` AND level = $${paramIndex}`;
      params.push(level);
      paramIndex++;
    }

    const result = await pool.query(query, params);

    return NextResponse.json({
      success: true,
      deletedCount: result.rowCount,
    });

  } catch (error) {
    console.error('Error deleting logs:', error);
    return NextResponse.json(
      {
        success: false,
        error: 'Failed to delete logs',
        details: error instanceof Error ? error.message : 'Unknown error',
      },
      { status: 500 }
    );
  }
}