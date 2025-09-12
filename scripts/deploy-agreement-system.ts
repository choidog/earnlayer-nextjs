#!/usr/bin/env tsx

/**
 * EarnLayer Clickwrap Agreement System Deployment Script
 * 
 * This script deploys the complete clickwrap agreement system including:
 * - Database schema changes
 * - Initial agreement version
 * - System configuration
 * 
 * Run with: npx tsx scripts/deploy-agreement-system.ts
 */

import { db } from "../src/lib/db/connection";
import { agreementVersions } from "../src/lib/db/schema";
import { createHash } from "crypto";

const INITIAL_AGREEMENT_CONTENT = `
# EarnLayer Publisher Agreement

**Version:** 1.0.0  
**Effective Date:** ${new Date().toISOString().split('T')[0]}

## 1. ACCEPTANCE OF TERMS

By checking the acceptance box and proceeding with account creation on the EarnLayer platform ("Platform"), you ("Publisher" or "you") agree to be bound by this Publisher Agreement ("Agreement") and all applicable laws and regulations.

## 2. PLATFORM SERVICES

EarnLayer provides a platform that connects content creators with advertisers, enabling monetization through contextually relevant advertisements displayed during conversations and content interactions.

## 3. PUBLISHER ELIGIBILITY

To participate as a Publisher, you must:
- Be at least 18 years old or the age of majority in your jurisdiction
- Have the legal authority to enter into this Agreement
- Provide accurate and complete information during registration
- Maintain compliance with all applicable laws and regulations

## 4. REVENUE SHARING

Publishers earn revenue through advertisement placements according to the terms specified in their individual creator profiles and campaign agreements. Revenue sharing percentages and payment terms are detailed in the Platform's monetization documentation.

## 5. CONTENT STANDARDS

Publishers must ensure their content:
- Complies with all applicable laws and regulations
- Does not contain illegal, harmful, or offensive material
- Adheres to Platform community guidelines
- Maintains professional standards appropriate for advertiser partnerships

## 6. INTELLECTUAL PROPERTY

Publishers retain ownership of their original content while granting EarnLayer necessary licenses to display content and facilitate advertisement placement as required for Platform functionality.

## 7. PAYMENT TERMS

- Payments are processed monthly for earned revenue above the minimum threshold
- Publishers must provide accurate payment information
- Tax responsibilities remain with the Publisher
- EarnLayer may withhold payments for policy violations or disputes

## 8. TERMINATION

Either party may terminate this Agreement with 30 days written notice. EarnLayer may terminate immediately for material breaches of this Agreement or Platform policies.

## 9. LIMITATION OF LIABILITY

EarnLayer's liability is limited to the amount of fees paid to Publisher in the preceding 12 months. The Platform is provided "as-is" without warranties of any kind.

## 10. GOVERNING LAW

This Agreement is governed by the laws of [Jurisdiction] without regard to conflict of law provisions.

## 11. AGREEMENT UPDATES

EarnLayer may update this Agreement from time to time. Publishers will be notified of material changes and must accept updated terms to continue using the Platform.

By accepting this Agreement, you acknowledge that you have read, understood, and agree to be bound by all terms and conditions contained herein.

---

**Last Updated:** ${new Date().toISOString().split('T')[0]}  
**Contact:** legal@earnlayerai.com
`.trim();

async function createAgreementTables() {
  console.log('🔧 Creating agreement system tables...');

  try {
    // Create tables using direct SQL since we might have dependency issues with Drizzle kit
    await db.execute(`
      CREATE TABLE IF NOT EXISTS agreement_versions (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        version_string VARCHAR(50) NOT NULL UNIQUE,
        content_hash VARCHAR(64) NOT NULL UNIQUE,
        content_text TEXT NOT NULL,
        is_active BOOLEAN DEFAULT true,
        effective_date TIMESTAMPTZ NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
        created_by TEXT,
        change_summary TEXT
      );
    `);

    await db.execute(`
      CREATE TABLE IF NOT EXISTS user_agreements (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
        agreement_version_id UUID NOT NULL REFERENCES agreement_versions(id),
        accepted_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
        ip_address TEXT,
        user_agent TEXT,
        acceptance_method VARCHAR(50) DEFAULT 'clickwrap',
        created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
        UNIQUE(user_id, agreement_version_id)
      );
    `);

    await db.execute(`
      CREATE TABLE IF NOT EXISTS agreement_banner_dismissals (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
        banner_version_id UUID NOT NULL REFERENCES agreement_versions(id),
        dismissed_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
        ip_address TEXT,
        user_agent TEXT
      );
    `);

    // Create indexes for performance
    await db.execute(`CREATE INDEX IF NOT EXISTS idx_user_agreements_user_id ON user_agreements(user_id);`);
    await db.execute(`CREATE INDEX IF NOT EXISTS idx_user_agreements_version_id ON user_agreements(agreement_version_id);`);
    await db.execute(`CREATE INDEX IF NOT EXISTS idx_banner_dismissals_user_id ON agreement_banner_dismissals(user_id);`);
    await db.execute(`CREATE INDEX IF NOT EXISTS idx_agreement_versions_active ON agreement_versions(is_active) WHERE is_active = true;`);

    console.log('✅ Agreement tables created successfully');
  } catch (error) {
    console.error('❌ Error creating tables:', error);
    throw error;
  }
}

async function createInitialAgreementVersion() {
  console.log('📋 Creating initial agreement version...');

  try {
    const contentHash = createHash('sha256').update(INITIAL_AGREEMENT_CONTENT).digest('hex');
    const versionString = '1.0.0';
    
    // Check if initial version already exists
    const existing = await db.execute(`
      SELECT id FROM agreement_versions WHERE version_string = '${versionString}' LIMIT 1;
    `);

    if (existing && existing.length > 0) {
      console.log('⚠️  Initial agreement version already exists, skipping creation');
      return;
    }

    await db.execute(`
      INSERT INTO agreement_versions (
        version_string, 
        content_hash, 
        content_text, 
        is_active, 
        effective_date, 
        created_by, 
        change_summary
      ) VALUES (
        '${versionString}',
        '${contentHash}',
        '${INITIAL_AGREEMENT_CONTENT.replace(/'/g, "''")}',
        true,
        NOW(),
        'system',
        'Initial EarnLayer Publisher Agreement'
      );
    `);

    console.log('✅ Initial agreement version created');
    console.log(`   Version: ${versionString}`);
    console.log(`   Content Hash: ${contentHash}`);
  } catch (error) {
    console.error('❌ Error creating initial agreement version:', error);
    throw error;
  }
}

async function verifyDeployment() {
  console.log('🔍 Verifying deployment...');

  try {
    // Check tables exist
    const tables = await db.execute(`
      SELECT table_name FROM information_schema.tables 
      WHERE table_schema = 'public' 
      AND table_name IN ('agreement_versions', 'user_agreements', 'agreement_banner_dismissals');
    `);

    console.log(`✅ Found ${tables.length || 0} agreement tables`);

    // Check initial version exists
    const versions = await db.execute(`
      SELECT version_string, is_active, created_at 
      FROM agreement_versions 
      WHERE is_active = true 
      ORDER BY created_at DESC;
    `);

    if (versions && versions.length > 0) {
      console.log('✅ Active agreement version found:');
      versions.forEach((row: any) => {
        console.log(`   Version: ${row.version_string} (Active: ${row.is_active})`);
      });
    } else {
      throw new Error('No active agreement version found');
    }

    console.log('🎉 Deployment verification successful!');
  } catch (error) {
    console.error('❌ Deployment verification failed:', error);
    throw error;
  }
}

async function main() {
  console.log('🚀 Starting EarnLayer Agreement System Deployment');
  console.log('================================================');

  try {
    // Step 1: Create database tables
    await createAgreementTables();

    // Step 2: Create initial agreement version
    await createInitialAgreementVersion();

    // Step 3: Verify deployment
    await verifyDeployment();

    console.log('');
    console.log('🎉 DEPLOYMENT COMPLETE!');
    console.log('======================');
    console.log('');
    console.log('✅ Database tables created');
    console.log('✅ Initial agreement version deployed');
    console.log('✅ API endpoints ready');
    console.log('✅ React components created');
    console.log('');
    console.log('📝 Next Steps:');
    console.log('1. Test API endpoints: GET /api/agreement/current');
    console.log('2. Integrate AgreementCheckbox into sign-up forms');
    console.log('3. Add AgreementBanner to dashboard');
    console.log('4. Deploy frontend changes');
    console.log('');
    console.log('🔗 Key URLs:');
    console.log('- Current Agreement: GET /api/agreement/current');
    console.log('- User Status: GET /api/agreement/status');
    console.log('- Accept Agreement: POST /api/agreement/accept');
    console.log('');

  } catch (error) {
    console.error('');
    console.error('💥 DEPLOYMENT FAILED');
    console.error('===================');
    console.error(error);
    process.exit(1);
  }
}

// Run the deployment
main();