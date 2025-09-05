console.log("🔧 Auth Route - Loading...");

async function logFullRequest(request: Request, method: string) {
  const url = new URL(request.url);
  const headers = Object.fromEntries(request.headers.entries());
  
  let body = null;
  try {
    // Clone request to read body without consuming it
    const cloned = request.clone();
    const text = await cloned.text();
    if (text) {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
  } catch (error) {
    body = "Could not read body";
  }

  console.log("🔍 FULL REQUEST ANALYSIS:");
  console.log("📋 Method:", method);
  console.log("📋 URL:", request.url);
  console.log("📋 Pathname:", url.pathname);
  console.log("📋 Search params:", Object.fromEntries(url.searchParams));
  console.log("📋 Headers:", JSON.stringify(headers, null, 2));
  console.log("📋 Body:", JSON.stringify(body, null, 2));
  console.log("📋 Origin:", headers.origin || "No origin header");
  console.log("📋 Referer:", headers.referer || "No referer header");
  console.log("📋 User-Agent:", headers['user-agent'] || "No user-agent");
  console.log("📋 Content-Type:", headers['content-type'] || "No content-type");
  console.log("📋 Cookie:", headers.cookie || "No cookies");
  console.log("🔍 END REQUEST ANALYSIS\n");
}

async function GET(request: Request) {
  await logFullRequest(request, "GET");
  
  try {
    // Import auth here to avoid initialization issues
    const { auth } = await import("@/lib/auth/config");
    console.log("🔧 Auth instance loaded successfully");
    
    const response = await auth.handler(request);
    console.log("✅ Auth GET response status:", response.status);
    
    // Log response headers
    const responseHeaders = Object.fromEntries(response.headers.entries());
    console.log("📤 Response headers:", JSON.stringify(responseHeaders, null, 2));
    
    return response;
  } catch (error) {
    console.error("❌ Auth GET error:", error);
    console.error("Error details:", {
      message: error.message,
      stack: error.stack,
      name: error.name
    });
    return new Response(JSON.stringify({ error: "Internal Server Error", details: error.message }), { 
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }
}

async function POST(request: Request) {
  await logFullRequest(request, "POST");
  
  try {
    // Import auth here to avoid initialization issues
    const { auth } = await import("@/lib/auth/config");
    console.log("🔧 Auth instance loaded successfully");
    
    const response = await auth.handler(request);
    console.log("✅ Auth POST response status:", response.status);
    
    // Log response headers and try to read response body
    const responseHeaders = Object.fromEntries(response.headers.entries());
    console.log("📤 Response headers:", JSON.stringify(responseHeaders, null, 2));
    
    // Try to log response body (clone to avoid consuming)
    try {
      const cloned = response.clone();
      const responseText = await cloned.text();
      if (responseText) {
        console.log("📤 Response body:", responseText.substring(0, 500) + (responseText.length > 500 ? "..." : ""));
      }
    } catch {
      console.log("📤 Could not read response body");
    }
    
    return response;
  } catch (error) {
    console.error("❌ Auth POST error:", error);
    console.error("Error details:", {
      message: error.message,
      stack: error.stack,
      name: error.name
    });
    return new Response(JSON.stringify({ error: "Internal Server Error", details: error.message }), { 
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }
}

export { GET, POST };