// Simple debug script to test MCP hyperlink ads
const { createConnection } = require('postgres');
const OpenAI = require('openai');

const openai = new OpenAI({ 
  apiKey: process.env.OPENAI_API_KEY || require('dotenv').config().parsed.OPENAI_API_KEY 
});

const sql = createConnection(process.env.DATABASE_URL || 'postgresql://casper@localhost:5432/earnlayer_typescript');

async function getEmbedding(text) {
  const response = await openai.embeddings.create({
    model: 'text-embedding-3-small',
    input: text
  });
  return response.data[0].embedding;
}

async function testHyperlinkAds() {
  try {
    console.log('🔍 Testing hyperlink ads query...');
    
    // Generate embedding for "toolhouse"
    const queryEmbedding = await getEmbedding('toolhouse');
    console.log(`✅ Generated embedding: ${queryEmbedding.length} dimensions`);
    
    // Test direct SQL query
    const results = await sql`
      WITH q AS (SELECT ${JSON.stringify(queryEmbedding)}::vector AS emb)
      SELECT 
        a.title,
        a.ad_type,
        1 - (a.embedding <-> q.emb) AS similarity
      FROM ads a
      JOIN ad_campaigns ac ON ac.id = a.campaign_id
      JOIN q ON true
      WHERE a.ad_type = 'hyperlink'
        AND ac.status = 'active'
        AND a.status = 'active'
        AND a.deleted_at IS NULL
        AND ac.deleted_at IS NULL
        AND a.embedding IS NOT NULL
      ORDER BY similarity DESC
      LIMIT 5
    `;
    
    console.log(`📊 Query results: ${results.length} ads found`);
    results.forEach((row, i) => {
      console.log(`  ${i+1}. ${row.title} (similarity: ${row.similarity.toFixed(4)})`);
    });
    
    // Check ads above different thresholds
    const above01 = results.filter(r => r.similarity >= 0.01);
    const above005 = results.filter(r => r.similarity >= 0.005);
    const above001 = results.filter(r => r.similarity >= 0.001);
    
    console.log(`📊 Ads above thresholds:`);
    console.log(`  >= 0.01: ${above01.length} ads`);
    console.log(`  >= 0.005: ${above005.length} ads`);
    console.log(`  >= 0.001: ${above001.length} ads`);
    
    await sql.end();
    
  } catch (error) {
    console.error('❌ Test failed:', error);
    process.exit(1);
  }
}

testHyperlinkAds();