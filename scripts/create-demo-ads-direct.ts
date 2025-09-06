#!/usr/bin/env tsx

import { config } from "dotenv";
import { drizzle } from "drizzle-orm/node-postgres";
import { Client } from "pg";
import crypto from "crypto";

// Load environment variables
if (process.env.NODE_ENV !== "production") {
  config({ path: ".env.local" });
}

// Define schema inline to avoid imports
const adCampaigns = {
  id: 'id',
  advertiserId: 'advertiser_id',
  name: 'name',
  startDate: 'start_date',
  endDate: 'end_date',
  budget: 'budget',
  status: 'status',
  createdAt: 'created_at',
  updatedAt: 'updated_at',
  deletedAt: 'deleted_at'
};

const ads = {
  id: 'id',
  campaignId: 'campaign_id',
  title: 'title',
  targetUrl: 'target_url',
  adType: 'ad_type',
  pricingModel: 'pricing_model',
  content: 'content',
  status: 'status',
  createdAt: 'created_at',
  updatedAt: 'updated_at',
  deletedAt: 'deleted_at'
};

async function createDemoAdsDirectly() {
  // Use Railway's database connection string - pgvector should be configured now
  const databaseUrl = "postgresql://postgres:TPyLaFqJiPjWEuIJzWCOJnecfvEuaQHf@postgres.railway.internal:5432/earnlayer";
  
  const client = new Client({
    connectionString: databaseUrl,
  });

  try {
    console.log("🔌 Connecting to database...");
    await client.connect();

    console.log("🧹 Cleaning up existing demo data...");
    
    // Delete existing demo ads
    await client.query("DELETE FROM ads WHERE title LIKE '[DEMO]%'");
    console.log("✅ Deleted existing demo ads");
    
    // Delete existing demo campaigns
    await client.query("DELETE FROM ad_campaigns WHERE name LIKE '[DEMO]%'");
    console.log("✅ Deleted existing demo campaigns");

    console.log("📊 Creating demo campaigns...");
    
    const campaignIds = [];
    const campaigns = [
      '[DEMO] Creator Tools & Productivity',
      '[DEMO] Tech Services & SaaS',
      '[DEMO] Education & Learning',
      '[DEMO] Crypto & Finance',
      '[DEMO] Design & Creative',
      '[DEMO] Marketing & Growth',
      '[DEMO] Development Tools',
      '[DEMO] Lifestyle & Health'
    ];

    for (const campaignName of campaigns) {
      const campaignId = crypto.randomUUID();
      campaignIds.push(campaignId);
      
      await client.query(`
        INSERT INTO ad_campaigns (
          id, advertiser_id, name, start_date, end_date, 
          budget, status, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      `, [
        campaignId,
        crypto.randomUUID(),
        campaignName,
        new Date(),
        new Date(Date.now() + 365 * 24 * 60 * 60 * 1000), // 1 year from now
        10000, // $100.00 budget
        'active',
        new Date(),
        new Date()
      ]);
    }
    
    console.log(`✅ Created ${campaignIds.length} demo campaigns`);

    console.log("🎯 Creating demo ads...");
    
    const demoAds = [
      // Creator Tools & Productivity
      { campaignIndex: 0, title: '[DEMO] Notion - All-in-one workspace', url: 'https://notion.so', type: 'hyperlink', content: 'Organize your life and work in one place. Notes, tasks, wikis & databases.' },
      { campaignIndex: 0, title: '[DEMO] Canva Pro - Design made easy', url: 'https://canva.com/pro', type: 'hyperlink', content: 'Create stunning visuals with professional templates and AI-powered design tools.' },
      { campaignIndex: 0, title: '[DEMO] Loom - Screen recording', url: 'https://loom.com', type: 'hyperlink', content: 'Record and share video messages instantly. Perfect for tutorials and team updates.' },
      
      // Tech Services & SaaS
      { campaignIndex: 1, title: '[DEMO] Vercel - Deploy with confidence', url: 'https://vercel.com', type: 'hyperlink', content: 'The platform for frontend developers. Deploy instantly with global edge network.' },
      { campaignIndex: 1, title: '[DEMO] Supabase - Backend as a Service', url: 'https://supabase.com', type: 'hyperlink', content: 'Open source Firebase alternative. Database, auth, storage, and real-time subscriptions.' },
      { campaignIndex: 1, title: '[DEMO] Stripe - Online payments', url: 'https://stripe.com', type: 'hyperlink', content: 'Accept payments and manage your business online. Trusted by millions of companies.' },
      
      // Education & Learning
      { campaignIndex: 2, title: '[DEMO] Coursera Plus - Learn anything', url: 'https://coursera.org/plus', type: 'hyperlink', content: 'Unlimited access to 7,000+ courses from top universities and companies.' },
      { campaignIndex: 2, title: '[DEMO] MasterClass - Learn from the best', url: 'https://masterclass.com', type: 'hyperlink', content: 'Online classes taught by world-renowned experts and celebrities.' },
      { campaignIndex: 2, title: '[DEMO] Skillshare - Creative classes', url: 'https://skillshare.com', type: 'hyperlink', content: 'Thousands of classes on design, business, tech and more. Start creating today.' },
      
      // Crypto & Finance
      { campaignIndex: 3, title: '[DEMO] Coinbase - Buy crypto safely', url: 'https://coinbase.com', type: 'hyperlink', content: 'The most trusted way to buy, sell, and manage crypto. Secure and regulated.' },
      { campaignIndex: 3, title: '[DEMO] Mint - Personal finance', url: 'https://mint.com', type: 'hyperlink', content: 'Track spending, create budgets, and get your credit score for free.' },
      { campaignIndex: 3, title: '[DEMO] Robinhood - Commission-free trading', url: 'https://robinhood.com', type: 'hyperlink', content: 'Invest in stocks, ETFs, and crypto with no commission fees.' },
      
      // Design & Creative
      { campaignIndex: 4, title: '[DEMO] Adobe Creative Cloud', url: 'https://adobe.com/creativecloud', type: 'hyperlink', content: 'Complete set of creative tools for photography, design, video, and web.' },
      { campaignIndex: 4, title: '[DEMO] Figma - Design collaboration', url: 'https://figma.com', type: 'hyperlink', content: 'The collaborative interface design tool. Design, prototype, and gather feedback.' },
      { campaignIndex: 4, title: '[DEMO] Unsplash+ - Premium photos', url: 'https://unsplash.com/plus', type: 'hyperlink', content: 'Unlimited downloads of high-quality photos without attribution required.' },
      
      // Marketing & Growth
      { campaignIndex: 5, title: '[DEMO] Mailchimp - Email marketing', url: 'https://mailchimp.com', type: 'hyperlink', content: 'Turn emails into revenue. Easy email marketing and automation platform.' },
      { campaignIndex: 5, title: '[DEMO] Hubspot CRM - Grow better', url: 'https://hubspot.com', type: 'hyperlink', content: 'Free CRM software with everything you need to organize, track, and build better relationships.' },
      { campaignIndex: 5, title: '[DEMO] Buffer - Social media management', url: 'https://buffer.com', type: 'hyperlink', content: 'Plan, publish, and analyze your social media content across all platforms.' },
      
      // Development Tools
      { campaignIndex: 6, title: '[DEMO] GitHub Pro - Code collaboration', url: 'https://github.com/pricing', type: 'hyperlink', content: 'Advanced collaboration features for software development teams.' },
      { campaignIndex: 6, title: '[DEMO] Linear - Issue tracking', url: 'https://linear.app', type: 'hyperlink', content: 'The issue tracking tool you\'ll enjoy using. Built for high-performance teams.' },
      { campaignIndex: 6, title: '[DEMO] Railway - Deploy anything', url: 'https://railway.app', type: 'hyperlink', content: 'Deploy your code with zero configuration. From prototype to production.' },
      
      // Lifestyle & Health
      { campaignIndex: 7, title: '[DEMO] Calm - Meditation & Sleep', url: 'https://calm.com', type: 'hyperlink', content: 'The #1 app for meditation and sleep. Reduce anxiety and improve your well-being.' },
      { campaignIndex: 7, title: '[DEMO] MyFitnessPal - Calorie tracker', url: 'https://myfitnesspal.com', type: 'hyperlink', content: 'Lose weight with the world\'s most popular nutrition and food tracking app.' },
      { campaignIndex: 7, title: '[DEMO] Headspace - Mindfulness', url: 'https://headspace.com', type: 'hyperlink', content: 'Guided meditation, sleep stories, and mindfulness exercises for a better life.' }
    ];

    let adCount = 0;
    for (const ad of demoAds) {
      await client.query(`
        INSERT INTO ads (
          id, campaign_id, title, target_url, ad_type, 
          pricing_model, content, status, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
      `, [
        crypto.randomUUID(),
        campaignIds[ad.campaignIndex],
        ad.title,
        ad.url,
        ad.type,
        'cpm', // Cost per mille
        ad.content,
        'active',
        new Date(),
        new Date()
      ]);
      adCount++;
    }
    
    console.log(`✅ Created ${adCount} demo ads`);

    // Verify the created data
    const campaignResult = await client.query("SELECT COUNT(*) as count FROM ad_campaigns WHERE name LIKE '[DEMO]%'");
    const adResult = await client.query("SELECT COUNT(*) as count FROM ads WHERE title LIKE '[DEMO]%'");
    
    console.log(`📊 Final count: ${campaignResult.rows[0].count} campaigns, ${adResult.rows[0].count} ads`);
    console.log("🎉 Demo ads created successfully!");

  } catch (error) {
    console.error("❌ Error creating demo ads:", error);
    process.exit(1);
  } finally {
    await client.end();
  }
}

createDemoAdsDirectly().catch(console.error);