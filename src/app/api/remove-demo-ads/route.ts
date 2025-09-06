import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { adCampaigns, ads } from "@/lib/db/schema";
import { like, or } from "drizzle-orm";

export async function POST(request: NextRequest) {
  console.log('🧹 [CLEANUP] Removing all demo ads...');

  try {
    // First, find and delete all demo ads (those with [DEMO] in title)
    console.log('🎯 [CLEANUP] Finding demo ads...');
    const demoAdsResult = await db
      .delete(ads)
      .where(like(ads.title, '[DEMO]%'))
      .returning();

    console.log(`✅ [CLEANUP] Deleted ${demoAdsResult.length} demo ads`);

    // Then, find and delete all demo campaigns (those with [DEMO] in name)
    console.log('📊 [CLEANUP] Finding demo campaigns...');
    const demoCampaignsResult = await db
      .delete(adCampaigns)
      .where(like(adCampaigns.name, '[DEMO]%'))
      .returning();

    console.log(`✅ [CLEANUP] Deleted ${demoCampaignsResult.length} demo campaigns`);

    // Summary by type for deleted ads
    const deletedAdsByType = demoAdsResult.reduce((acc, ad) => {
      acc[ad.adType] = (acc[ad.adType] || 0) + 1;
      return acc;
    }, {} as Record<string, number>);

    console.log('📊 [CLEANUP] Deleted demo ads by type:');
    Object.entries(deletedAdsByType).forEach(([type, count]) => {
      console.log(`   ${type}: ${count} ads`);
    });

    console.log('🎉 [CLEANUP] Demo cleanup completed successfully!');

    return NextResponse.json({
      success: true,
      message: 'Demo ads and campaigns removed successfully',
      deleted: {
        campaigns: demoCampaignsResult.length,
        ads: demoAdsResult.length,
        adsByType: deletedAdsByType
      },
      campaignNames: demoCampaignsResult.map(c => c.name),
      note: 'All [DEMO] prefixed content has been removed from the database'
    });

  } catch (error: any) {
    console.error('❌ [CLEANUP] Error removing demo ads:', error);
    return NextResponse.json({
      success: false,
      message: 'Failed to remove demo ads',
      error: error.message
    }, { status: 500 });
  }
}