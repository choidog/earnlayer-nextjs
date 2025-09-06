import { NextRequest, NextResponse } from "next/server";
import { Client } from 'pg';

export async function POST(request: NextRequest) {
  console.log('🚀 [VECTOR] Starting vector extension installation...');
  
  const client = new Client({
    connectionString: process.env.DATABASE_URL,
  });

  try {
    console.log('🔗 [VECTOR] Connecting to database...');
    await client.connect();
    
    console.log('📦 [VECTOR] Installing vector extension...');
    await client.query('CREATE EXTENSION IF NOT EXISTS vector;');
    
    console.log('✅ [VECTOR] Vector extension installed successfully');
    console.log('🔍 [VECTOR] Verifying extension...');
    
    const result = await client.query(`
      SELECT extname, extversion 
      FROM pg_extension 
      WHERE extname = 'vector'
    `);
    
    if (result.rows.length > 0) {
      console.log('✅ [VECTOR] Vector extension verified:', result.rows[0]);
      return NextResponse.json({
        success: true,
        message: 'Vector extension installed and verified',
        extension: result.rows[0]
      });
    } else {
      console.log('❌ [VECTOR] Vector extension not found after installation');
      return NextResponse.json({
        success: false,
        message: 'Vector extension installation failed'
      }, { status: 500 });
    }
    
  } catch (error: any) {
    console.error('❌ [VECTOR] Error installing vector extension:', error);
    return NextResponse.json({
      success: false,
      message: 'Failed to install vector extension',
      error: error.message
    }, { status: 500 });
  } finally {
    await client.end();
    console.log('🔗 [VECTOR] Database connection closed');
  }
}