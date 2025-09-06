import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { adCampaigns, ads } from "@/lib/db/schema";
import crypto from "crypto";

export async function POST(request: NextRequest) {
  console.log('🚀 [QUICK-SEED] Starting quick seed of display ads...');

  try {
    // Create simple campaign with generated UUID
    console.log('📊 [QUICK-SEED] Creating simple campaign...');
    const campaignId = crypto.randomUUID();
    
    const campaign = await db
      .insert(adCampaigns)
      .values({
        id: campaignId,
        advertiserId: crypto.randomUUID(),
        name: 'Quick Seed Campaign',
        startDate: new Date(),
        endDate: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
        budgetAmount: '1000.000000',
        spentAmount: '0.000000',
        currency: 'USD',
        status: 'active',
        timeZone: 'UTC'
      })
      .returning();

    console.log(`✅ [QUICK-SEED] Created campaign: ${campaign[0].id}`);

    // Create basic ads for each type
    console.log('🎯 [QUICK-SEED] Creating basic ads...');
    const displayAds = await db
      .insert(ads)
      .values([
        {
          id: crypto.randomUUID(),
          campaignId: campaignId,
          title: 'Creator Tools',
          content: 'Professional tools for content creators. Start your free trial!',
          targetUrl: 'https://creatortools.com',
          adType: 'banner',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '0.500000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaignId,
          title: 'Special Offer',
          content: 'Limited time: Get 50% off premium tools for creators!',
          targetUrl: 'https://creatortools.com/offer',
          adType: 'popup',
          status: 'active',
          placement: 'chat',
          pricingModel: 'cpc',
          bidAmount: '1.000000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaignId,
          title: 'Success Stories',
          content: 'Watch how creators doubled their income using our platform.',
          targetUrl: 'https://creatortools.com/success',
          adType: 'video',
          status: 'active',
          placement: 'chat_inline',
          pricingModel: 'cpm',
          bidAmount: '2.000000',
          currency: 'USD'
        }
      ])
      .returning();

    console.log(`✅ [QUICK-SEED] Created ${displayAds.length} ads`);

    return NextResponse.json({
      success: true,
      message: 'Quick seed completed',
      campaign: campaign[0].id,
      ads: displayAds.length,
      adIds: displayAds.map(ad => ad.id)
    });

  } catch (error: any) {
    console.error('❌ [QUICK-SEED] Error:', error);
    return NextResponse.json({
      success: false,
      message: 'Quick seed failed',
      error: error.message
    }, { status: 500 });
  }
}