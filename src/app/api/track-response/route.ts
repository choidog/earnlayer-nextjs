import { NextRequest, NextResponse } from "next/server";
import { adServingService } from "@/lib/services/ad-serving";
import { budgetTrackingService } from "@/lib/services/budget-tracking";
import { z } from "zod";

const trackResponseSchema = z.object({
  impression_id: z.string().uuid(),
  event_type: z.enum(["click", "view", "conversion"]),
  sid: z.string().optional(), // Sub-ID for affiliate tracking
  metadata: z.record(z.any()).optional(),
});

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const validatedData = trackResponseSchema.parse(body);

    const { impression_id, event_type, sid, metadata } = validatedData;

    // Prepare tracking metadata
    const trackingMetadata = {
      ...metadata,
      sid,
      timestamp: new Date().toISOString(),
      user_agent: request.headers.get('user-agent') || undefined,
      referer: request.headers.get('referer') || undefined,
      ip: request.headers.get('x-forwarded-for') || 
          request.headers.get('x-real-ip') || 
          'unknown',
    };

    let response: any = {
      success: true,
      impression_id,
      event_type,
      tracked_at: new Date().toISOString(),
    };

    switch (event_type) {
      case "click":
        // Record click and process billing
        const clickId = await adServingService.recordClick(
          impression_id,
          trackingMetadata
        );
        
        // Process click billing for CPC ads
        await budgetTrackingService.processClickBilling(clickId);
        
        response.click_id = clickId;
        response.message = "Click tracked and billed successfully";
        break;

      case "view":
        // For impression tracking (if needed for CPM)
        await budgetTrackingService.processImpressionBilling(impression_id);
        
        response.message = "Impression view tracked successfully";
        break;

      case "conversion":
        // For affiliate/conversion tracking
        response.message = "Conversion tracked successfully";
        response.sid = sid;
        // Additional conversion logic could go here
        break;

      default:
        throw new Error(`Unsupported event type: ${event_type}`);
    }

    return NextResponse.json(response);

  } catch (error) {
    console.error("Error tracking response:", error);
    
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { 
          error: "Invalid request data", 
          details: error.errors 
        },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { 
        error: "Failed to track response",
        message: error instanceof Error ? error.message : "Unknown error"
      },
      { status: 500 }
    );
  }
}

// GET endpoint for affiliate link redirects with tracking
export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  
  const impressionId = searchParams.get('impression_id');
  const redirectUrl = searchParams.get('url');
  const sid = searchParams.get('sid');

  if (!impressionId || !redirectUrl) {
    return NextResponse.json(
      { error: "impression_id and url parameters are required" },
      { status: 400 }
    );
  }

  try {
    // Track the click
    const clickId = await adServingService.recordClick(impressionId, {
      sid,
      redirect_url: redirectUrl,
      timestamp: new Date().toISOString(),
      user_agent: request.headers.get('user-agent') || undefined,
      referer: request.headers.get('referer') || undefined,
    });

    // Process billing
    await budgetTrackingService.processClickBilling(clickId);

    // Build final URL with SID if provided
    let finalUrl = redirectUrl;
    if (sid) {
      const url = new URL(redirectUrl);
      url.searchParams.set('sid', sid);
      finalUrl = url.toString();
    }

    // Redirect to the target URL
    return NextResponse.redirect(finalUrl, 302);

  } catch (error) {
    console.error("Error in affiliate redirect:", error);
    
    // Still redirect even if tracking fails
    return NextResponse.redirect(redirectUrl, 302);
  }
}