import { NextRequest, NextResponse } from "next/server";
import crypto from "crypto";

export async function POST(request: NextRequest) {
  const { db } = await import("@/lib/db/connection");
  const { adCampaigns, ads } = await import("@/lib/db/schema");
  console.log('🎯 [DEMO-ADS] Creating demo ads for testing...');

  try {
    // Create demo campaigns - clearly marked as DEMO
    console.log('📊 [DEMO-ADS] Creating demo campaigns...');
    const demoCampaigns = await db
      .insert(adCampaigns)
      .values([
        {
          id: crypto.randomUUID(),
          advertiserId: crypto.randomUUID(),
          name: '[DEMO] Creator Tools & Productivity',
          startDate: new Date(),
          endDate: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
          budgetAmount: '10000.000000',
          spentAmount: '0.000000',
          currency: 'USD',
          status: 'active',
          timeZone: 'UTC'
        },
        {
          id: crypto.randomUUID(),
          advertiserId: crypto.randomUUID(),
          name: '[DEMO] Tech & Business Services',
          startDate: new Date(),
          endDate: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
          budgetAmount: '8000.000000',
          spentAmount: '0.000000',
          currency: 'USD',
          status: 'active',
          timeZone: 'UTC'
        },
        {
          id: crypto.randomUUID(),
          advertiserId: crypto.randomUUID(),
          name: '[DEMO] Education & Learning',
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

    console.log(`✅ [DEMO-ADS] Created ${demoCampaigns.length} demo campaigns`);

    const [campaign1, campaign2, campaign3] = demoCampaigns;

    // Create comprehensive demo ads across multiple categories
    console.log('🎯 [DEMO-ADS] Creating demo ads across categories...');
    const demoAds = await db
      .insert(ads)
      .values([
        // ===== BANNER ADS =====
        {
          id: crypto.randomUUID(),
          campaignId: campaign1.id,
          title: '[DEMO] Creator Tools Pro',
          content: 'Boost your content creation with professional tools. 30% off first month!',
          targetUrl: 'https://demo.creatortools.com',
          adType: 'banner',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '0.500000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign2.id,
          title: '[DEMO] CloudHost Pro',
          content: 'Reliable cloud hosting for developers. 99.9% uptime guaranteed.',
          targetUrl: 'https://demo.cloudhost.com',
          adType: 'banner',
          status: 'active',
          placement: 'content_promo',
          pricingModel: 'cpc',
          bidAmount: '0.750000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign3.id,
          title: '[DEMO] CodeAcademy Plus',
          content: 'Learn programming from scratch. Interactive courses + certificates.',
          targetUrl: 'https://demo.codeacademy.com',
          adType: 'banner',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpm',
          bidAmount: '2.000000',
          currency: 'USD'
        },

        // ===== POPUP ADS =====
        {
          id: crypto.randomUUID(),
          campaignId: campaign1.id,
          title: '[DEMO] Limited Time: 50% Off!',
          content: 'Get premium creator tools at half price. Only 48 hours left! Join 50,000+ successful creators.',
          targetUrl: 'https://demo.creatortools.com/offer',
          adType: 'popup',
          status: 'active',
          placement: 'chat',
          pricingModel: 'cpm',
          bidAmount: '3.000000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign2.id,
          title: '[DEMO] Free Business Consultation',
          content: 'Get a free 30-minute business strategy session with our experts. Book now!',
          targetUrl: 'https://demo.bizconulst.com/book',
          adType: 'popup',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpc',
          bidAmount: '2.500000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign3.id,
          title: '[DEMO] Free Coding Bootcamp',
          content: 'Join our 7-day free coding bootcamp. Learn React, Node.js, and more!',
          targetUrl: 'https://demo.bootcamp.dev',
          adType: 'popup',
          status: 'active',
          placement: 'chat',
          pricingModel: 'cpc',
          bidAmount: '1.800000',
          currency: 'USD'
        },

        // ===== VIDEO ADS =====
        {
          id: crypto.randomUUID(),
          campaignId: campaign1.id,
          title: '[DEMO] Creator Success Stories',
          content: 'Watch how creators increased income by 300% using our platform. Real results, real people.',
          targetUrl: 'https://demo.creatortools.com/success',
          adType: 'video',
          status: 'active',
          placement: 'chat_inline',
          pricingModel: 'cpm',
          bidAmount: '5.000000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign2.id,
          title: '[DEMO] SaaS Growth Masterclass',
          content: 'See how to scale from $0 to $100K MRR. 15-minute case study video.',
          targetUrl: 'https://demo.saasgroth.com/video',
          adType: 'video',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '2.000000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign3.id,
          title: '[DEMO] Programming in 2025',
          content: 'Watch: The programming languages and frameworks you need to learn this year.',
          targetUrl: 'https://demo.progming2025.com',
          adType: 'video',
          status: 'active',
          placement: 'chat_inline',
          pricingModel: 'cpm',
          bidAmount: '3.500000',
          currency: 'USD'
        },

        // ===== THINKING ADS =====
        {
          id: crypto.randomUUID(),
          campaignId: campaign1.id,
          title: '[DEMO] Creator Tip',
          content: 'Pro tip: 85% of successful creators use analytics to optimize their content strategy.',
          targetUrl: 'https://demo.creatortools.com/analytics',
          adType: 'thinking',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpm',
          bidAmount: '1.200000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign2.id,
          title: '[DEMO] Business Insight',
          content: 'Did you know? Companies using automation save an average of 15 hours per week.',
          targetUrl: 'https://demo.automation.biz',
          adType: 'thinking',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpm',
          bidAmount: '1.000000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign3.id,
          title: '[DEMO] Dev Fact',
          content: 'Fact: Developers who use modern frameworks are 40% more productive than those using legacy tools.',
          targetUrl: 'https://demo.moderndev.tools',
          adType: 'thinking',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpm',
          bidAmount: '0.800000',
          currency: 'USD'
        },

        // ===== TEXT ADS =====
        {
          id: crypto.randomUUID(),
          campaignId: campaign1.id,
          title: '[DEMO] Content Calendar Template',
          content: 'Download our proven content calendar template used by 10,000+ creators. Organize your content like a pro!',
          targetUrl: 'https://demo.creatortools.com/calendar',
          adType: 'text',
          status: 'active',
          placement: 'chat_inline',
          pricingModel: 'cpc',
          bidAmount: '0.400000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign2.id,
          title: '[DEMO] Startup Funding Guide',
          content: 'Free 100-page guide: How to raise your first $1M. Includes pitch deck templates and investor contacts.',
          targetUrl: 'https://demo.startup-funding.guide',
          adType: 'text',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '0.600000',
          currency: 'USD'
        },
        {
          id: crypto.randomUUID(),
          campaignId: campaign3.id,
          title: '[DEMO] React Cheat Sheet',
          content: 'Ultimate React hooks cheat sheet. Download PDF with 50+ examples and best practices.',
          targetUrl: 'https://demo.react-cheatsheet.dev',
          adType: 'text',
          status: 'active',
          placement: 'chat_inline',
          pricingModel: 'cpc',
          bidAmount: '0.350000',
          currency: 'USD'
        },

        // ===== ADDITIONAL CATEGORY COVERAGE =====
        // E-commerce
        {
          id: crypto.randomUUID(),
          campaignId: campaign2.id,
          title: '[DEMO] Shopify Store Builder',
          content: 'Build your online store in minutes. 14-day free trial + premium themes included.',
          targetUrl: 'https://demo.storebuilder.com',
          adType: 'banner',
          status: 'active',
          placement: 'content_promo',
          pricingModel: 'cpc',
          bidAmount: '1.200000',
          currency: 'USD'
        },

        // Finance/Crypto
        {
          id: crypto.randomUUID(),
          campaignId: campaign2.id,
          title: '[DEMO] Crypto Trading Course',
          content: 'Master cryptocurrency trading with our proven strategies. Join 5,000+ successful traders.',
          targetUrl: 'https://demo.cryptotrading.academy',
          adType: 'popup',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpm',
          bidAmount: '4.000000',
          currency: 'USD'
        },

        // Health/Fitness
        {
          id: crypto.randomUUID(),
          campaignId: campaign3.id,
          title: '[DEMO] AI Fitness Coach',
          content: 'Get personalized workouts powered by AI. Track progress and reach your fitness goals.',
          targetUrl: 'https://demo.aifitness.coach',
          adType: 'video',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpm',
          bidAmount: '3.000000',
          currency: 'USD'
        },

        // Marketing/SEO
        {
          id: crypto.randomUUID(),
          campaignId: campaign1.id,
          title: '[DEMO] SEO Toolkit',
          content: 'Boost your website rankings with our all-in-one SEO toolkit. Free keyword research included.',
          targetUrl: 'https://demo.seotoolkit.pro',
          adType: 'text',
          status: 'active',
          placement: 'sidebar',
          pricingModel: 'cpc',
          bidAmount: '0.800000',
          currency: 'USD'
        },

        // Design/Creative
        {
          id: crypto.randomUUID(),
          campaignId: campaign1.id,
          title: '[DEMO] Design Templates',
          content: 'Premium design templates for social media, presentations, and branding. Instant download.',
          targetUrl: 'https://demo.designtemplates.studio',
          adType: 'thinking',
          status: 'active',
          placement: 'default',
          pricingModel: 'cpm',
          bidAmount: '1.500000',
          currency: 'USD'
        }
      ])
      .returning();

    console.log(`✅ [DEMO-ADS] Created ${demoAds.length} demo ads`);

    // Summary by type and category
    const adsByType = demoAds.reduce((acc, ad) => {
      acc[ad.adType] = (acc[ad.adType] || 0) + 1;
      return acc;
    }, {} as Record<string, number>);

    console.log('📊 [DEMO-ADS] Demo ad distribution:');
    Object.entries(adsByType).forEach(([type, count]) => {
      console.log(`   ${type}: ${count} ads`);
    });

    console.log('🎉 [DEMO-ADS] Demo ads created successfully!');
    console.log('⚠️ [DEMO-ADS] Remember: All ads are marked with [DEMO] prefix for easy identification and removal');

    return NextResponse.json({
      success: true,
      message: 'Demo ads created successfully',
      campaigns: demoCampaigns.length,
      ads: demoAds.length,
      adsByType,
      categories: [
        'Creator Tools & Productivity',
        'Cloud Hosting & Tech Services', 
        'Education & Learning',
        'E-commerce',
        'Finance/Crypto',
        'Health/Fitness',
        'Marketing/SEO',
        'Design/Creative'
      ],
      note: 'All ads prefixed with [DEMO] for easy removal later'
    });

  } catch (error: any) {
    console.error('❌ [DEMO-ADS] Error creating demo ads:', error);
    return NextResponse.json({
      success: false,
      message: 'Failed to create demo ads',
      error: error.message
    }, { status: 500 });
  }
}