#!/usr/bin/env tsx

/**
 * Populate the database with sample display ads for all types
 * This will create campaigns and ads for banner, popup, video, and thinking ad types
 */

import { db } from '../src/lib/db/connection';
import { adCampaigns, ads } from '../src/lib/db/schema';
import { v4 as uuidv4 } from 'uuid';

async function populateDisplayAds() {
  console.log('🚀 [POPULATE] Starting to populate display ads...');

  try {
    // Create sample ad campaigns
    console.log('📊 [POPULATE] Creating ad campaigns...');
    const campaigns = await db
      .insert(adCampaigns)
      .values([
        {
          id: uuidv4(),
          advertiserId: uuidv4(), // Demo advertiser ID
          name: 'Creator Tools Campaign',
          startDate: new Date(),
          endDate: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000), // 1 year from now
          budgetAmount: '10000.000000',
          spentAmount: '0.000000',
          currency: 'USD',
          status: 'active',
          timeZone: 'UTC'
        },
        {
          id: uuidv4(),
          advertiserId: uuidv4(),
          name: 'Productivity Tools Campaign',
          startDate: new Date(),
          endDate: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
          budgetAmount: '5000.000000',
          spentAmount: '0.000000',
          currency: 'USD',
          status: 'active',
          timeZone: 'UTC'
        }
      ])
      .returning();

    console.log(`✅ [POPULATE] Created ${campaigns.length} campaigns`);

    const campaign1Id = campaigns[0].id;
    const campaign2Id = campaigns[1].id;

    // Create display ads for all types
    console.log('🎯 [POPULATE] Creating display ads...');
    const displayAds = await db
      .insert(ads)
      .values([
        // Banner Ads
        {
          id: uuidv4(),
          campaignId: campaign1Id,
          title: 'Creator Tools Pro',
          content: 'Boost your content creation with professional tools. Get 30% off your first month!',
          targetUrl: 'https://creatortools.com/pro?ref=earnlayer',
          adType: 'banner',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '0.500000',
          currency: 'USD'
        },
        {
          id: uuidv4(),
          campaignId: campaign2Id,
          title: 'AI Productivity Suite',
          content: 'Transform your workflow with AI-powered productivity tools. Free trial available!',
          targetUrl: 'https://aiproductivity.com/trial?ref=earnlayer',
          adType: 'banner',
          status: 'active',
          placement: 'content_promo',
          pricingModel: 'cpc',
          bidAmount: '0.750000',
          currency: 'USD'
        },
        
        // Popup Ads
        {
          id: uuidv4(),
          campaignId: campaign1Id,
          title: 'Limited Time Offer!',
          content: 'Get premium creator tools at 50% off. Only 48 hours left! Join thousands of successful creators.',
          targetUrl: 'https://creatortools.com/offer?ref=earnlayer',
          adType: 'popup',
          status: 'active',
          placement: 'chat',
          pricingModel: 'cpm',
          bidAmount: '2.000000',
          currency: 'USD'
        },
        {
          id: uuidv4(),
          campaignId: campaign2Id,
          title: 'Free Masterclass',
          content: 'Learn the secrets of top creators! Join our exclusive masterclass on content monetization.',
          targetUrl: 'https://masterclass.creatortools.com?ref=earnlayer',
          adType: 'popup',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpc',
          bidAmount: '1.250000',
          currency: 'USD'
        },
        
        // Video Ads
        {
          id: uuidv4(),
          campaignId: campaign1Id,
          title: 'Creator Success Stories',
          content: 'Watch how creators increased their income by 300% using our platform. Real results, real stories.',
          targetUrl: 'https://creatortools.com/success-stories?ref=earnlayer',
          adType: 'video',
          status: 'active',
          placement: 'chat_inline',
          pricingModel: 'cpm',
          bidAmount: '5.000000',
          currency: 'USD'
        },
        {
          id: uuidv4(),
          campaignId: campaign2Id,
          title: 'AI Writing Assistant Demo',
          content: 'See how AI can write your content 10x faster. Watch this 2-minute demo and get started today!',
          targetUrl: 'https://aiwriter.com/demo?ref=earnlayer',
          adType: 'video',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '1.500000',
          currency: 'USD'
        },
        
        // Thinking Ads (shown during AI processing)
        {
          id: uuidv4(),
          campaignId: campaign1Id,
          title: 'Creator Tip',
          content: 'Pro tip: 85% of successful creators use analytics to optimize their content strategy.',
          targetUrl: 'https://creatortools.com/analytics?ref=earnlayer',
          adType: 'thinking',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpm',
          bidAmount: '1.000000',
          currency: 'USD'
        },
        {
          id: uuidv4(),
          campaignId: campaign2Id,
          title: 'Did You Know?',
          content: 'Creators who use scheduling tools save 5+ hours per week on content management.',
          targetUrl: 'https://scheduling.creatortools.com?ref=earnlayer',
          adType: 'thinking',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpm',
          bidAmount: '0.800000',
          currency: 'USD'
        },
        
        // Text Ads
        {
          id: uuidv4(),
          campaignId: campaign1Id,
          title: 'Content Calendar Template',
          content: 'Download our proven content calendar template used by 10,000+ creators. Organize your content like a pro!',
          targetUrl: 'https://creatortools.com/calendar?ref=earnlayer',
          adType: 'text',
          status: 'active',
          placement: 'chat_inline',
          pricingModel: 'cpc',
          bidAmount: '0.300000',
          currency: 'USD'
        },
        {
          id: uuidv4(),
          campaignId: campaign2Id,
          title: 'Monetization Guide',
          content: 'Free 50-page guide: How to turn your content into a 6-figure business. Download now!',
          targetUrl: 'https://monetization.guide/download?ref=earnlayer',
          adType: 'text',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '0.400000',
          currency: 'USD'
        }
      ])
      .returning();

    console.log(`✅ [POPULATE] Created ${displayAds.length} display ads`);

    // Summary
    const adsByType = displayAds.reduce((acc, ad) => {
      acc[ad.adType] = (acc[ad.adType] || 0) + 1;
      return acc;
    }, {} as Record<string, number>);

    console.log('📊 [POPULATE] Ad distribution by type:');
    Object.entries(adsByType).forEach(([type, count]) => {
      console.log(`   ${type}: ${count} ads`);
    });

    console.log('🎉 [POPULATE] Successfully populated database with display ads!');

  } catch (error) {
    console.error('❌ [POPULATE] Error populating display ads:', error);
    process.exit(1);
  }
}

if (require.main === module) {
  populateDisplayAds()
    .then(() => {
      console.log('✅ [POPULATE] Script completed successfully');
      process.exit(0);
    })
    .catch((error) => {
      console.error('💥 [POPULATE] Script failed:', error);
      process.exit(1);
    });
}