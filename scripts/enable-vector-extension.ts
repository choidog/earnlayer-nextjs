#!/usr/bin/env tsx

/**
 * Enable the vector extension in production database
 * This fixes the "type vector does not exist" error in production
 */

import { Client } from 'pg';

async function enableVectorExtension() {
  const client = new Client({
    connectionString: process.env.DATABASE_URL,
  });

  try {
    console.log('🔗 Connecting to database...');
    await client.connect();
    
    console.log('📦 Installing vector extension...');
    await client.query('CREATE EXTENSION IF NOT EXISTS vector;');
    
    console.log('✅ Vector extension installed successfully');
    console.log('🔍 Verifying extension...');
    
    const result = await client.query(`
      SELECT extname, extversion 
      FROM pg_extension 
      WHERE extname = 'vector'
    `);
    
    if (result.rows.length > 0) {
      console.log('✅ Vector extension verified:', result.rows[0]);
    } else {
      console.log('❌ Vector extension not found after installation');
    }
    
  } catch (error) {
    console.error('❌ Error enabling vector extension:', error);
    process.exit(1);
  } finally {
    await client.end();
    console.log('🔗 Database connection closed');
  }
}

if (require.main === module) {
  enableVectorExtension()
    .then(() => {
      console.log('🎉 Script completed successfully');
      process.exit(0);
    })
    .catch((error) => {
      console.error('💥 Script failed:', error);
      process.exit(1);
    });
}