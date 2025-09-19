import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import { agreementVersions } from '../src/lib/db/schema';
import { eq } from 'drizzle-orm';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error('DATABASE_URL environment variable is required');
}

const sql = postgres(connectionString);
const db = drizzle(sql);

async function updateAgreement() {
  try {
    console.log('Updating agreement to version 2.0.0...');

    // First, deactivate all existing versions
    await db
      .update(agreementVersions)
      .set({ isActive: false })
      .where(eq(agreementVersions.isActive, true));

    console.log('Deactivated existing agreement versions');

    // Insert new agreement version
    const newAgreement = await db
      .insert(agreementVersions)
      .values({
        versionString: '2.0.0',
        contentHash: '14c6059bb11c02ca57496726332b0d4d3c9d7fa7b6592471f372b7ddf82f315e',
        contentText: `### EarnLayer Publisher Agreement

**Last Updated:** September 11, 2025
**Version:** 2.0.0

## 1. Introduction

Welcome to EarnLayer! This Publisher Agreement ("Agreement") governs your use of the EarnLayer platform as a content publisher. By creating content on our platform, you agree to these terms.

## 2. Publisher Responsibilities

### 2.1 Content Standards
- All content must be original or properly licensed
- Content must comply with applicable laws and regulations
- No misleading, false, or deceptive information
- Respect intellectual property rights of others

### 2.2 Quality Requirements
- Maintain high-quality, engaging content
- Provide accurate descriptions and metadata
- Respond promptly to user inquiries and feedback
- Keep content updated and relevant

## 3. Revenue Sharing

### 3.1 Payment Structure
- Publishers receive 70% of net revenue from their content
- EarnLayer retains 30% to cover platform costs and development
- Payments are processed monthly for earnings above $10

### 3.2 Revenue Sources
- Direct content purchases
- Subscription revenue allocation
- Advertising revenue (where applicable)
- Premium feature access

## 4. Content Ownership and Licensing

### 4.1 Publisher Rights
- You retain ownership of your original content
- You grant EarnLayer a non-exclusive license to display and distribute your content
- You may remove your content at any time with 30 days notice

### 4.2 Platform Rights
- EarnLayer may moderate content for quality and compliance
- Right to remove content that violates this agreement
- Right to promote your content across the platform

## 5. Prohibited Activities

- Spam or automated content generation
- Plagiarism or copyright infringement
- Manipulation of ratings or engagement metrics
- Sharing of inappropriate or harmful content
- Violation of user privacy

## 6. Account Management

### 6.1 Account Security
- Maintain secure login credentials
- Report suspicious activity immediately
- Do not share account access with unauthorized parties

### 6.2 Account Termination
- Either party may terminate with 30 days written notice
- Immediate termination for material breach
- Final payment processed within 60 days of termination

## 7. Platform Changes

EarnLayer reserves the right to:
- Update platform features and functionality
- Modify revenue sharing terms with 60 days notice
- Change content guidelines with reasonable notice

## 8. Support and Disputes

### 8.1 Publisher Support
- Technical support available via help center
- Content guidance and best practices provided
- Regular platform updates and communications

### 8.2 Dispute Resolution
- Good faith negotiation required first
- Mediation through agreed neutral party
- Governing law: [Jurisdiction to be specified]

## 9. Compliance and Legal

### 9.1 Regulatory Compliance
- Publishers must comply with applicable tax obligations
- Adherence to data protection regulations (GDPR, CCPA)
- Content must meet advertising standards where applicable

### 9.2 Limitation of Liability
- Platform provided "as is" without warranties
- Limited liability for platform downtime or technical issues
- Publishers responsible for backing up their content

## 10. Agreement Updates

This agreement may be updated periodically. Publishers will be notified of material changes at least 30 days in advance. Continued use of the platform constitutes acceptance of updated terms.

---

**Contact Information:**
For questions about this agreement, please contact: legal@earnlayer.com

**Effective Date:** This agreement version 2.0.0 is effective as of September 11, 2025.`,
        isActive: true,
        effectiveDate: new Date(),
        changeSummary: 'Updated publisher agreement with enhanced content standards, clearer revenue sharing terms, improved dispute resolution process, and strengthened compliance requirements.'
      })
      .returning();

    console.log('Successfully inserted new agreement version:', newAgreement[0]);
    console.log('Agreement update completed successfully!');

  } catch (error) {
    console.error('Error updating agreement:', error);
    throw error;
  } finally {
    await sql.end();
  }
}

updateAgreement().catch(console.error);