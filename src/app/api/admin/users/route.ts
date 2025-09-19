import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { creators, apiKeys } from "@/lib/db/schema";
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
  rejectionReason?: string | null;
  lastApprovalCheck?: string;
  apiKeyCount: number;
  lastLoginAt?: string;
  hasCreatorProfile: boolean;
  creatorId?: string | null;
}

export async function GET(request: NextRequest) {
  // Check admin authentication
  if (!(await isAdminAuthenticated(request))) {
    return NextResponse.json(
      { error: "Unauthorized - Admin access required" },
      { status: 401 }
    );
  }

  try {
    console.log("Admin users endpoint hit");

    const { searchParams } = new URL(request.url);
    const filter = searchParams.get('filter') || 'all';
    const search = searchParams.get('search') || '';

    console.log("Filter:", filter, "Search:", search);

    // First, let's do a simple query to see if we have any users at all (using Better Auth table)
    const allUsers = await db.execute(sql`SELECT id, email, name, email_verified, created_at FROM "user" LIMIT 5`);
    console.log("Total users found:", allUsers.rows.length);
    console.log("Sample users:", allUsers.rows.map(u => ({ id: u.id, email: u.email, name: u.name })));

    // Get all users with creator info and statistics using raw SQL
    let rawUsers;
    if (search) {
      const searchPattern = `%${search}%`;
      rawUsers = await db.execute(sql`
        SELECT
          u.id,
          u.email,
          u.name,
          u.created_at,
          u.updated_at,
          u.email_verified,
          u.image as picture,
          c.id as creator_id,
          c.approval_status,
          c.approval_date,
          c.rejection_reason,
          c.last_approval_check,
          COUNT(DISTINCT ak.id) as api_key_count
        FROM "user" u
        LEFT JOIN creators c ON u.id = c.user_id
        LEFT JOIN api_keys ak ON u.id = ak.user_id
        WHERE (u.email ILIKE ${searchPattern} OR u.name ILIKE ${searchPattern})
        GROUP BY u.id, u.email, u.name, u.created_at, u.updated_at, u.email_verified, u.image,
                 c.id, c.approval_status, c.approval_date, c.rejection_reason, c.last_approval_check
        ORDER BY u.created_at DESC
      `);
    } else {
      rawUsers = await db.execute(sql`
        SELECT
          u.id,
          u.email,
          u.name,
          u.created_at,
          u.updated_at,
          u.email_verified,
          u.image as picture,
          c.id as creator_id,
          c.approval_status,
          c.approval_date,
          c.rejection_reason,
          c.last_approval_check,
          COUNT(DISTINCT ak.id) as api_key_count
        FROM "user" u
        LEFT JOIN creators c ON u.id = c.user_id
        LEFT JOIN api_keys ak ON u.id = ak.user_id
        GROUP BY u.id, u.email, u.name, u.created_at, u.updated_at, u.email_verified, u.image,
                 c.id, c.approval_status, c.approval_date, c.rejection_reason, c.last_approval_check
        ORDER BY u.created_at DESC
      `);
    }
    console.log("Raw users from complex query:", rawUsers.length);
    console.log("Sample raw user:", rawUsers[0]);

    // Transform and filter the results
    const users: AdminUser[] = (rawUsers as any[])
      .map((user: any) => ({
        id: user.id,
        email: user.email,
        name: user.name || 'Unknown',
        createdAt: user.created_at ? new Date(user.created_at).toISOString() : new Date().toISOString(),
        emailVerified: user.email_verified,
        approvalStatus: user.approval_status || 'pending',
        approvalDate: user.approval_date ? new Date(user.approval_date).toISOString() : undefined,
        rejectionReason: user.rejection_reason || undefined,
        lastApprovalCheck: user.last_approval_check ? new Date(user.last_approval_check).toISOString() : undefined,
        apiKeyCount: parseInt(user.api_key_count) || 0,
        lastLoginAt: undefined,
        hasCreatorProfile: !!user.creator_id,
        creatorId: user.creator_id
      }))
      .filter((user: AdminUser) => {
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