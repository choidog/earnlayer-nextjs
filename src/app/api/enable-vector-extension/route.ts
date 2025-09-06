export async function POST() {
  try {
    const { db } = await import("@/lib/db/connection");
    
    console.log("🧩 Enabling pgvector extension...");
    
    // Enable the vector extension
    await db.execute(`CREATE EXTENSION IF NOT EXISTS vector;` as any);
    console.log("✅ pgvector extension enabled successfully!");

    // Verify the extension is installed
    const result = await db.execute(`
      SELECT extname, extversion 
      FROM pg_extension 
      WHERE extname = 'vector';
    ` as any);
    
    console.log("🔍 Extension verification result:", result);
    
    if (result.length > 0) {
      return Response.json({
        success: true,
        message: "pgvector extension enabled successfully",
        extension: {
          name: result[0].extname,
          version: result[0].extversion
        },
        timestamp: new Date().toISOString(),
      });
    } else {
      return Response.json({
        success: false,
        message: "pgvector extension was not found after installation attempt",
        timestamp: new Date().toISOString(),
      }, { status: 500 });
    }

  } catch (error) {
    console.error("❌ Error enabling pgvector extension:", error);
    return Response.json({ 
      success: false,
      error: "Failed to enable pgvector extension", 
      message: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString(),
    }, { status: 500 });
  }
}