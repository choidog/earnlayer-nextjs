#!/usr/bin/env tsx
/**
 * Generate Embeddings for Imported Ads
 * Updates ads with vector embeddings for similarity search
 */

import { config } from "dotenv";
config({ path: ".env.local" });

import { db } from "../src/lib/db/connection";
import { ads } from "../src/lib/db/schema";
import { embeddingService } from "../src/lib/services/embeddings";
import { eq, isNull } from "drizzle-orm";

async function generateEmbeddings() {
  console.log("🚀 Generating embeddings for imported ads...\n");
  
  try {
    // Get ads without embeddings
    const adsToProcess = await db
      .select()
      .from(ads)
      .where(isNull(ads.embedding))
      .limit(50); // Process in batches

    if (adsToProcess.length === 0) {
      console.log("✅ All ads already have embeddings!");
      return;
    }

    console.log(`📊 Found ${adsToProcess.length} ads to process`);

    let processed = 0;
    for (const ad of adsToProcess) {
      console.log(`Processing ${processed + 1}/${adsToProcess.length}: "${ad.title}"`);
      
      try {
        // Generate embedding for title + content
        const embedding = await embeddingService.generateAdEmbedding(
          ad.title, 
          ad.content
        );

        // Update ad with embedding
        await db
          .update(ads)
          .set({
            embedding: `[${embedding.join(",")}]`
          })
          .where(eq(ads.id, ad.id));

        processed++;
        console.log(`   ✅ Generated ${embedding.length}-dimension embedding`);

        // Rate limiting delay
        if (processed % 5 === 0) {
          console.log("   ⏳ Rate limiting delay...");
          await new Promise(resolve => setTimeout(resolve, 1000));
        }

      } catch (error) {
        console.error(`   ❌ Failed to process ad ${ad.id}:`, error);
      }
    }

    console.log(`\n🎉 Successfully generated embeddings for ${processed} ads!`);
    
    // Verify final count
    const totalWithEmbeddings = await db
      .select({ count: ads.id })
      .from(ads)
      .where(isNull(ads.embedding));

    console.log(`📊 Remaining ads without embeddings: ${totalWithEmbeddings.length}`);

  } catch (error) {
    console.error("💥 Failed to generate embeddings:", error);
    process.exit(1);
  }
}

generateEmbeddings();