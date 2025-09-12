import { NextRequest, NextResponse } from "next/server";
import { isAdminAuthenticated } from "../authenticate/route";
import { agreementService } from "@/services/AgreementService";
import { z } from "zod";

const createVersionSchema = z.object({
  content: z.string().min(1, "Agreement content is required"),
  versionString: z.string().min(1, "Version string is required"),
  changeSummary: z.string().optional(),
});

export async function GET(request: NextRequest) {
  // Check admin authentication
  if (!(await isAdminAuthenticated(request))) {
    return NextResponse.json(
      { error: "Unauthorized - Admin access required" },
      { status: 401 }
    );
  }

  try {
    const currentVersion = await agreementService.getCurrentVersion();
    const statistics = await agreementService.getAcceptanceStatistics();

    return NextResponse.json({
      success: true,
      data: {
        currentVersion: {
          id: currentVersion.id,
          version: currentVersion.versionString,
          effectiveDate: currentVersion.effectiveDate.toISOString(),
          createdAt: currentVersion.createdAt.toISOString(),
          createdBy: currentVersion.createdBy,
          changeSummary: currentVersion.changeSummary,
          contentHash: currentVersion.contentHash,
          isActive: currentVersion.isActive,
        },
        statistics,
      }
    });
  } catch (error) {
    console.error("Error fetching agreement data:", error);
    return NextResponse.json(
      { error: "Failed to fetch agreement data" },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  // Check admin authentication
  if (!(await isAdminAuthenticated(request))) {
    return NextResponse.json(
      { error: "Unauthorized - Admin access required" },
      { status: 401 }
    );
  }

  try {
    const body = await request.json();
    const { content, versionString, changeSummary } = createVersionSchema.parse(body);

    const newVersion = await agreementService.createVersion(
      content,
      versionString,
      {
        createdBy: 'admin', // Could be enhanced to get actual admin user
        changeSummary,
      }
    );

    return NextResponse.json({
      success: true,
      data: {
        id: newVersion.id,
        version: newVersion.versionString,
        effectiveDate: newVersion.effectiveDate.toISOString(),
        createdAt: newVersion.createdAt.toISOString(),
        contentHash: newVersion.contentHash,
        message: `Agreement version ${versionString} created successfully`
      }
    });

  } catch (error) {
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { error: "Invalid request data", details: error.errors },
        { status: 400 }
      );
    }

    console.error("Error creating agreement version:", error);
    return NextResponse.json(
      { error: "Failed to create agreement version" },
      { status: 500 }
    );
  }
}