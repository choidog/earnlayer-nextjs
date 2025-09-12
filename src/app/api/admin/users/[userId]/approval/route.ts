import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { creators, user } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { isAdminAuthenticated } from "../../../authenticate/route";

const approvalSchema = z.object({
  status: z.enum(['pending', 'approved', 'rejected', 'suspended']),
  reason: z.string().optional(),
});

// Simple audit log storage (in production, this should be a proper database table)
interface AuditLogEntry {
  timestamp: string;
  action: string;
  userId: string;
  newStatus: string;
  reason?: string;
  adminIP: string;
  sessionId?: string;
}

const auditLog: AuditLogEntry[] = [];

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ userId: string }> }
) {
  // Check admin authentication
  if (!isAdminAuthenticated(request)) {
    return NextResponse.json(
      { error: "Unauthorized - Admin access required" },
      { status: 401 }
    );
  }

  try {
    const { userId } = await params;
    const body = await request.json();
    const { status, reason } = approvalSchema.parse(body);

    // Validate user exists
    const userExists = await db
      .select({ id: user.id })
      .from(user)
      .where(eq(user.id, userId))
      .limit(1);

    if (userExists.length === 0) {
      return NextResponse.json(
        { error: "User not found" },
        { status: 404 }
      );
    }

    // Check if creator profile exists, create if needed
    let creatorRecord = await db
      .select()
      .from(creators)
      .where(eq(creators.userId, userId))
      .limit(1);

    if (creatorRecord.length === 0) {
      // Get user info to create creator profile
      const userInfo = await db
        .select()
        .from(user)
        .where(eq(user.id, userId))
        .limit(1);

      if (userInfo.length === 0) {
        return NextResponse.json(
          { error: "User not found" },
          { status: 404 }
        );
      }

      // Create creator profile
      const newCreator = await db
        .insert(creators)
        .values({
          userId: userId,
          name: userInfo[0].name || 'Unknown',
          email: userInfo[0].email,
          approvalStatus: status,
          approvalDate: status === 'approved' ? new Date() : null,
          rejectionReason: reason || null,
          lastApprovalCheck: new Date(),
        })
        .returning();

      creatorRecord = newCreator;
    } else {
      // Update existing creator record
      const updated = await db
        .update(creators)
        .set({
          approvalStatus: status,
          approvalDate: status === 'approved' ? new Date() : creatorRecord[0].approvalDate,
          rejectionReason: status === 'rejected' ? reason || null : null,
          lastApprovalCheck: new Date(),
          updatedAt: new Date(),
        })
        .where(eq(creators.userId, userId))
        .returning();

      creatorRecord = updated;
    }

    // Log the admin action
    const logEntry: AuditLogEntry = {
      timestamp: new Date().toISOString(),
      action: 'status_update',
      userId,
      newStatus: status,
      reason,
      adminIP: request.headers.get('x-forwarded-for') || request.headers.get('x-real-ip') || 'unknown',
      sessionId: request.cookies.get('admin-session')?.value,
    };
    
    auditLog.push(logEntry);
    
    // Keep only last 1000 audit entries (in production, use proper database)
    if (auditLog.length > 1000) {
      auditLog.splice(0, auditLog.length - 1000);
    }

    console.log(`Admin action: Updated user ${userId} status to ${status}`, {
      reason,
      adminIP: logEntry.adminIP,
      timestamp: logEntry.timestamp
    });

    return NextResponse.json({
      success: true,
      data: {
        userId,
        creatorId: creatorRecord[0].id,
        status,
        approvalDate: creatorRecord[0].approvalDate?.toISOString(),
        reason: creatorRecord[0].rejectionReason,
        updatedAt: new Date().toISOString()
      }
    });

  } catch (error) {
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { error: "Invalid request", details: error.errors },
        { status: 400 }
      );
    }

    console.error("Error updating user approval status:", error);
    return NextResponse.json(
      { error: "Failed to update approval status" },
      { status: 500 }
    );
  }
}

// GET endpoint to fetch audit log for a specific user
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ userId: string }> }
) {
  // Check admin authentication
  if (!isAdminAuthenticated(request)) {
    return NextResponse.json(
      { error: "Unauthorized - Admin access required" },
      { status: 401 }
    );
  }

  try {
    const { userId } = await params;

    // Get user's audit log entries
    const userAuditLog = auditLog
      .filter(entry => entry.userId === userId)
      .sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime())
      .slice(0, 50); // Return last 50 entries

    return NextResponse.json({
      success: true,
      data: {
        userId,
        auditLog: userAuditLog
      }
    });

  } catch (error) {
    console.error("Error fetching audit log:", error);
    return NextResponse.json(
      { error: "Failed to fetch audit log" },
      { status: 500 }
    );
  }
}