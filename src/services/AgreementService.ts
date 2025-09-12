import { db } from "@/lib/db/connection";
import { agreementVersions, userAgreements, agreementBannerDismissals } from "@/lib/db/schema";
import { eq, desc, and } from "drizzle-orm";
import { createHash } from "crypto";

export interface AgreementVersion {
  id: string;
  versionString: string;
  contentHash: string;
  contentText: string;
  isActive: boolean;
  effectiveDate: Date;
  createdAt: Date;
  createdBy?: string;
  changeSummary?: string;
}

export interface UserAgreementStatus {
  hasAcceptedCurrent: boolean;
  currentVersionAccepted?: AgreementVersion;
  acceptedAt?: Date;
  needsUpdate: boolean;
  latestVersion: AgreementVersion;
}

export interface AcceptanceMetadata {
  ipAddress?: string;
  userAgent?: string;
  acceptanceMethod?: string;
}

export interface VersionMetadata {
  createdBy?: string;
  changeSummary?: string;
}

export interface DismissalMetadata {
  ipAddress?: string;
  userAgent?: string;
}

export interface AgreementUpdate {
  newVersion: AgreementVersion;
  previousVersion?: AgreementVersion;
  requiresAcceptance: boolean;
}

export class AgreementService {
  /**
   * Get the current active agreement version
   */
  async getCurrentVersion(): Promise<AgreementVersion> {
    const versions = await db
      .select()
      .from(agreementVersions)
      .where(eq(agreementVersions.isActive, true))
      .orderBy(desc(agreementVersions.effectiveDate))
      .limit(1);

    if (versions.length === 0) {
      throw new Error("No active agreement version found");
    }

    return versions[0] as AgreementVersion;
  }

  /**
   * Get an agreement version by content hash
   */
  async getVersionByHash(hash: string): Promise<AgreementVersion | null> {
    const versions = await db
      .select()
      .from(agreementVersions)
      .where(eq(agreementVersions.contentHash, hash))
      .limit(1);

    return versions.length > 0 ? (versions[0] as AgreementVersion) : null;
  }

  /**
   * Create a new agreement version
   */
  async createVersion(
    content: string, 
    versionString: string, 
    metadata: VersionMetadata = {}
  ): Promise<AgreementVersion> {
    const contentHash = this.generateContentHash(content);
    const effectiveDate = new Date();

    // Deactivate previous versions
    await db
      .update(agreementVersions)
      .set({ isActive: false })
      .where(eq(agreementVersions.isActive, true));

    const newVersion = await db
      .insert(agreementVersions)
      .values({
        versionString,
        contentHash,
        contentText: content,
        isActive: true,
        effectiveDate,
        createdBy: metadata.createdBy,
        changeSummary: metadata.changeSummary,
      })
      .returning();

    return newVersion[0] as AgreementVersion;
  }

  /**
   * Get user's agreement status
   */
  async getUserAgreementStatus(userId: string): Promise<UserAgreementStatus> {
    const currentVersion = await this.getCurrentVersion();
    
    // Check if user has accepted the current version
    const userAcceptance = await db
      .select({
        version: agreementVersions,
        acceptance: userAgreements,
      })
      .from(userAgreements)
      .innerJoin(agreementVersions, eq(userAgreements.agreementVersionId, agreementVersions.id))
      .where(
        and(
          eq(userAgreements.userId, userId),
          eq(agreementVersions.id, currentVersion.id)
        )
      )
      .limit(1);

    const hasAcceptedCurrent = userAcceptance.length > 0;
    
    return {
      hasAcceptedCurrent,
      currentVersionAccepted: hasAcceptedCurrent ? (userAcceptance[0].version as AgreementVersion) : undefined,
      acceptedAt: hasAcceptedCurrent ? userAcceptance[0].acceptance.acceptedAt : undefined,
      needsUpdate: !hasAcceptedCurrent,
      latestVersion: currentVersion,
    };
  }

  /**
   * Check if user has accepted the current agreement
   */
  async hasAcceptedCurrent(userId: string): Promise<boolean> {
    const status = await this.getUserAgreementStatus(userId);
    return status.hasAcceptedCurrent;
  }

  /**
   * Record user agreement acceptance
   */
  async acceptAgreement(
    userId: string, 
    versionId: string, 
    metadata: AcceptanceMetadata = {}
  ): Promise<void> {
    // Verify the version exists and is active
    const version = await db
      .select()
      .from(agreementVersions)
      .where(and(
        eq(agreementVersions.id, versionId),
        eq(agreementVersions.isActive, true)
      ))
      .limit(1);

    if (version.length === 0) {
      throw new Error("Agreement version not found or inactive");
    }

    // Check if user already accepted this version
    const existing = await db
      .select()
      .from(userAgreements)
      .where(and(
        eq(userAgreements.userId, userId),
        eq(userAgreements.agreementVersionId, versionId)
      ))
      .limit(1);

    if (existing.length > 0) {
      // Already accepted, no need to create duplicate
      return;
    }

    // Record the acceptance
    await db
      .insert(userAgreements)
      .values({
        userId,
        agreementVersionId: versionId,
        ipAddress: metadata.ipAddress,
        userAgent: metadata.userAgent,
        acceptanceMethod: metadata.acceptanceMethod || 'clickwrap',
      });
  }

  /**
   * Check for agreement updates for a user
   */
  async checkForUpdates(userId: string): Promise<AgreementUpdate | null> {
    const status = await this.getUserAgreementStatus(userId);
    
    if (status.hasAcceptedCurrent) {
      return null; // User is up to date
    }

    // Get the user's most recent acceptance
    const lastAcceptance = await db
      .select({
        version: agreementVersions,
        acceptance: userAgreements,
      })
      .from(userAgreements)
      .innerJoin(agreementVersions, eq(userAgreements.agreementVersionId, agreementVersions.id))
      .where(eq(userAgreements.userId, userId))
      .orderBy(desc(userAgreements.acceptedAt))
      .limit(1);

    return {
      newVersion: status.latestVersion,
      previousVersion: lastAcceptance.length > 0 ? (lastAcceptance[0].version as AgreementVersion) : undefined,
      requiresAcceptance: true,
    };
  }

  /**
   * Dismiss banner for a specific version
   */
  async dismissBanner(
    userId: string, 
    versionId: string, 
    metadata: DismissalMetadata = {}
  ): Promise<void> {
    // Check if already dismissed
    const existing = await db
      .select()
      .from(agreementBannerDismissals)
      .where(and(
        eq(agreementBannerDismissals.userId, userId),
        eq(agreementBannerDismissals.bannerVersionId, versionId)
      ))
      .limit(1);

    if (existing.length > 0) {
      return; // Already dismissed
    }

    await db
      .insert(agreementBannerDismissals)
      .values({
        userId,
        bannerVersionId: versionId,
        ipAddress: metadata.ipAddress,
        userAgent: metadata.userAgent,
      });
  }

  /**
   * Check if user has dismissed banner for a specific version
   */
  async hasDismissedBanner(userId: string, versionId: string): Promise<boolean> {
    const dismissals = await db
      .select()
      .from(agreementBannerDismissals)
      .where(and(
        eq(agreementBannerDismissals.userId, userId),
        eq(agreementBannerDismissals.bannerVersionId, versionId)
      ))
      .limit(1);

    return dismissals.length > 0;
  }

  /**
   * Generate SHA-256 hash for content integrity
   */
  generateContentHash(content: string): string {
    return createHash('sha256').update(content).digest('hex');
  }

  /**
   * Validate content integrity using hash
   */
  async validateContentIntegrity(versionId: string): Promise<boolean> {
    const version = await db
      .select()
      .from(agreementVersions)
      .where(eq(agreementVersions.id, versionId))
      .limit(1);

    if (version.length === 0) {
      return false;
    }

    const expectedHash = this.generateContentHash(version[0].contentText);
    return expectedHash === version[0].contentHash;
  }

  /**
   * Get all agreements for a user (for audit purposes)
   */
  async getUserAgreementHistory(userId: string): Promise<Array<{
    version: AgreementVersion;
    acceptedAt: Date;
    ipAddress?: string;
    acceptanceMethod: string;
  }>> {
    const history = await db
      .select({
        version: agreementVersions,
        acceptance: userAgreements,
      })
      .from(userAgreements)
      .innerJoin(agreementVersions, eq(userAgreements.agreementVersionId, agreementVersions.id))
      .where(eq(userAgreements.userId, userId))
      .orderBy(desc(userAgreements.acceptedAt));

    return history.map(row => ({
      version: row.version as AgreementVersion,
      acceptedAt: row.acceptance.acceptedAt,
      ipAddress: row.acceptance.ipAddress || undefined,
      acceptanceMethod: row.acceptance.acceptanceMethod,
    }));
  }

  /**
   * Get acceptance statistics for admin dashboard
   */
  async getAcceptanceStatistics(): Promise<{
    totalUsers: number;
    acceptedCurrent: number;
    needingUpdate: number;
    acceptanceRate: number;
  }> {
    const currentVersion = await this.getCurrentVersion();
    
    // This would need to be implemented with proper SQL queries
    // For now, returning a placeholder structure
    const totalAcceptances = await db
      .select()
      .from(userAgreements)
      .where(eq(userAgreements.agreementVersionId, currentVersion.id));

    return {
      totalUsers: 0, // Would need to count from user table
      acceptedCurrent: totalAcceptances.length,
      needingUpdate: 0, // Would need complex query
      acceptanceRate: 0, // Calculated from above
    };
  }
}

// Export singleton instance
export const agreementService = new AgreementService();