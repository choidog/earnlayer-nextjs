// Debug script to check actual database schema
const { config } = require('dotenv');
const postgres = require('postgres');

// Load Railway environment variables
config({ path: '.env.local' });

const databaseUrl = process.env.DATABASE_URL || 'postgresql://postgres:TPyLaFqJiPjWEuIJzWCOJnecfvEuaQHf@postgres.railway.internal:5432/railway';

async function checkDatabaseSchema() {
  console.log('🔍 Connecting to database...');
  console.log('Database URL:', databaseUrl);
  
  const sql = postgres(databaseUrl, {
    prepare: false,
    max: 1,
  });

  try {
    // Check if verification table exists and its structure
    console.log('\n📋 Checking verification table structure:');
    const verificationSchema = await sql`
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns 
      WHERE table_name = 'verification' AND table_schema = 'public'
      ORDER BY ordinal_position;
    `;
    
    if (verificationSchema.length === 0) {
      console.log('❌ verification table does not exist');
    } else {
      console.log('✅ verification table exists:');
      verificationSchema.forEach(col => {
        console.log(`  - ${col.column_name}: ${col.data_type} ${col.is_nullable === 'NO' ? 'NOT NULL' : 'NULL'} ${col.column_default || ''}`);
      });
    }

    // Check all Better Auth related tables
    console.log('\n📋 Checking all Better Auth tables:');
    const authTables = await sql`
      SELECT table_name 
      FROM information_schema.tables 
      WHERE table_schema = 'public' 
      AND table_name IN ('user', 'account', 'session', 'verification', 'verification_token')
      ORDER BY table_name;
    `;
    
    console.log('Existing Better Auth tables:', authTables.map(t => t.table_name));

    // Check user table structure specifically
    console.log('\n📋 Checking user table structure:');
    const userSchema = await sql`
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns 
      WHERE table_name = 'user' AND table_schema = 'public'
      ORDER BY ordinal_position;
    `;
    
    if (userSchema.length === 0) {
      console.log('❌ user table does not exist');
    } else {
      console.log('✅ user table exists:');
      userSchema.forEach(col => {
        console.log(`  - ${col.column_name}: ${col.data_type} ${col.is_nullable === 'NO' ? 'NOT NULL' : 'NULL'} ${col.column_default || ''}`);
      });
    }

    // Check migrations applied
    console.log('\n📋 Checking applied migrations:');
    const migrations = await sql`
      SELECT migration_name, applied_at 
      FROM drizzle_migrations 
      ORDER BY applied_at DESC 
      LIMIT 10;
    `.catch(() => {
      console.log('❌ drizzle_migrations table does not exist');
      return [];
    });
    
    if (migrations.length > 0) {
      console.log('Recent migrations:');
      migrations.forEach(m => {
        console.log(`  - ${m.migration_name}: ${m.applied_at}`);
      });
    }

  } catch (error) {
    console.error('❌ Database check failed:', error.message);
  } finally {
    await sql.end();
  }
}

checkDatabaseSchema().catch(console.error);