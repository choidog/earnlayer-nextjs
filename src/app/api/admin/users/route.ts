import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { user, creators, apikey, session } from "@/lib/db/schema";
import { eq, sql, desc, and, isNull } from "drizzle-orm";
import { isAdminAuthenticated } from "../authenticate/route";

interface AdminUser {
  id: string;
  email: string;
  name: string;
  createdAt: string;
  emailVerified: boolean;
  approvalStatus: string;
  approvalDate?: string;
  rejectionReason?: string;
  lastApprovalCheck?: string;
  apiKeyCount: number;
  lastLoginAt?: string;
  hasCreatorProfile: boolean;
  creatorId?: string;
}

export async function GET(request: NextRequest) {
  // Check admin authentication
  if (!isAdminAuthenticated(request)) {
    return NextResponse.json(
      { error: "Unauthorized - Admin access required" },
      { status: 401 }
    );
  }

  try {
    const { searchParams } = new URL(request.url);
    const filter = searchParams.get('filter') || 'all'; // all, pending, approved, rejected, suspended
    const search = searchParams.get('search') || '';

    // Build the query
    let whereConditions = [];
    
    if (search) {
      whereConditions.push(
        sql`(${user.email} ILIKE ${'%' + search + '%'} OR ${user.name} ILIKE ${'%' + search + '%'})`
      );
    }

    // Get all users with creator info and statistics
    const usersQuery = db
      .select({
        id: user.id,
        email: user.email,
        name: user.name,
        createdAt: user.createdAt,
        updatedAt: user.updatedAt,
        emailVerified: user.emailVerified,
        image: user.image,
        // Creator info
        creatorId: creators.id,
        approvalStatus: creators.approvalStatus,
        approvalDate: creators.approvalDate,
        rejectionReason: creators.rejectionReason,
        lastApprovalCheck: creators.lastApprovalCheck,
        // Statistics
        apiKeyCount: sql<number>`COUNT(DISTINCT ${apikey.id})`,
        lastLoginAt: sql<string>`MAX(${session.createdAt})`,
      })
      .from(user)
      .leftJoin(creators, eq(user.id, creators.userId))
      .leftJoin(apikey, eq(user.id, apikey.userId))
      .leftJoin(session, eq(user.id, session.userId))
      .groupBy(
        user.id,
        user.email,
        user.name,
        user.createdAt,
        user.updatedAt,
        user.emailVerified,
        user.image,
        creators.id,
        creators.approvalStatus,
        creators.approvalDate,
        creators.rejectionReason,
        creators.lastApprovalCheck
      )
      .orderBy(desc(user.createdAt));

    // Add where conditions if any
    if (whereConditions.length > 0) {
      whereConditions.forEach(condition => {
        usersQuery.where(condition);
      });
    }

    const rawUsers = await usersQuery;

    // Transform and filter the results
    const users: AdminUser[] = rawUsers
      .map(user => ({
        id: user.id,
        email: user.email,
        name: user.name || 'Unknown',
        createdAt: user.createdAt?.toISOString() || new Date().toISOString(),
        emailVerified: user.emailVerified,
        approvalStatus: user.approvalStatus || 'pending',
        approvalDate: user.approvalDate?.toISOString(),
        rejectionReason: user.rejectionReason,
        lastApprovalCheck: user.lastApprovalCheck?.toISOString(),
        apiKeyCount: user.apiKeyCount || 0,
        lastLoginAt: user.lastLoginAt,
        hasCreatorProfile: !!user.creatorId,
        creatorId: user.creatorId
      }))
      .filter(user => {
        if (filter === 'all') return true;
        if (filter === 'pending') return user.approvalStatus === 'pending';
        if (filter === 'approved') return user.approvalStatus === 'approved';
        if (filter === 'rejected') return user.approvalStatus === 'rejected';
        if (filter === 'suspended') return user.approvalStatus === 'suspended';
        if (filter === 'no-creator') return !user.hasCreatorProfile;
        return true;
      });

    // Get summary statistics
    const stats = {
      total: users.length,
      pending: users.filter(u => u.approvalStatus === 'pending').length,
      approved: users.filter(u => u.approvalStatus === 'approved').length,
      rejected: users.filter(u => u.approvalStatus === 'rejected').length,
      suspended: users.filter(u => u.approvalStatus === 'suspended').length,
      withoutCreatorProfile: users.filter(u => !u.hasCreatorProfile).length,
    };

    return NextResponse.json({
      success: true,
      data: {
        users,
        stats,
        filter,
        search
      }
    });

  } catch (error) {
    console.error("Error fetching users for admin:", error);
    return NextResponse.json(
      { error: "Failed to fetch users" },
      { status: 500 }
    );
  }
}