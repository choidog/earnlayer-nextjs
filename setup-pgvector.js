const { Client } = require('pg');

async function setupPgvector() {
  // Connect to the pgvector database
  const client = new Client({
    connectionString: 'postgresql://postgres:TPyLaFqJiPjWEuIJzWCOJnecfvEuaQHf@pgvector-db.railway.internal:5432/earnlayer',
  });

  try {
    console.log('🔌 Connecting to pgvector database...');
    await client.connect();

    console.log('🧩 Enabling pgvector extension...');
    await client.query('CREATE EXTENSION IF NOT EXISTS vector;');
    
    console.log('🔍 Verifying vector extension...');
    const result = await client.query(`
      SELECT extname, extversion 
      FROM pg_extension 
      WHERE extname = 'vector';
    `);
    
    if (result.rows.length > 0) {
      console.log(`✅ pgvector extension enabled: ${result.rows[0].extname} v${result.rows[0].extversion}`);
    } else {
      console.log('❌ pgvector extension not found');
    }

    console.log('📊 Creating demo ads...');
    
    // Check if ads tables exist
    const tablesResult = await client.query(`
      SELECT table_name 
      FROM information_schema.tables 
      WHERE table_schema = 'public' 
      AND table_name IN ('ad_campaigns', 'ads')
      ORDER BY table_name;
    `);
    
    console.log('Available tables:', tablesResult.rows.map(r => r.table_name));
    
    if (tablesResult.rows.length >= 2) {
      // Clean up existing demo data
      await client.query("DELETE FROM ads WHERE title LIKE '[DEMO]%'");
      await client.query("DELETE FROM ad_campaigns WHERE name LIKE '[DEMO]%'");
      
      // Create demo campaign
      const campaignId = 'demo-campaign-' + Date.now();
      const advertiserId = 'demo-advertiser-' + Date.now();
      
      await client.query(`
        INSERT INTO ad_campaigns (
          id, advertiser_id, name, start_date, end_date, 
          budget, status, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      `, [
        campaignId,
        advertiserId,
        '[DEMO] Creator Tools',
        new Date(),
        new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
        10000,
        'active',
        new Date(),
        new Date()
      ]);

      // Create demo ads
      const demoAds = [
        { title: '[DEMO] Notion - All-in-one workspace', url: 'https://notion.so', content: 'Organize your life and work in one place.' },
        { title: '[DEMO] Canva Pro - Design made easy', url: 'https://canva.com/pro', content: 'Create stunning visuals with professional templates.' },
        { title: '[DEMO] Loom - Screen recording', url: 'https://loom.com', content: 'Record and share video messages instantly.' },
        { title: '[DEMO] Vercel - Deploy with confidence', url: 'https://vercel.com', content: 'The platform for frontend developers.' },
        { title: '[DEMO] Stripe - Online payments', url: 'https://stripe.com', content: 'Accept payments and manage your business online.' },
      ];

      for (const ad of demoAds) {
        const adId = 'demo-ad-' + Date.now() + '-' + Math.random().toString(36).substr(2, 9);
        
        await client.query(`
          INSERT INTO ads (
            id, campaign_id, title, target_url, ad_type, 
            pricing_model, content, status, created_at, updated_at
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        `, [
          adId,
          campaignId,
          ad.title,
          ad.url,
          'hyperlink',
          'cpm',
          ad.content,
          'active',
          new Date(),
          new Date()
        ]);
      }

      // Verify results
      const campaignCount = await client.query("SELECT COUNT(*) as count FROM ad_campaigns WHERE name LIKE '[DEMO]%'");
      const adCount = await client.query("SELECT COUNT(*) as count FROM ads WHERE title LIKE '[DEMO]%'");
      
      console.log(`✅ Created ${campaignCount.rows[0].count} campaigns and ${adCount.rows[0].count} ads`);
    } else {
      console.log('❌ Ad tables not found. Please run database migrations first.');
    }

  } catch (error) {
    console.error('❌ Error:', error);
  } finally {
    await client.end();
  }
}

setupPgvector();