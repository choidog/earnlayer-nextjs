import { NextRequest, NextResponse } from "next/server";

// GET /api/auth/callback/google - Handle Google OAuth callback
export async function GET(request: NextRequest) {
  try {
    console.log("🔧 OAuth Callback - Processing Google OAuth callback");

    const { searchParams } = new URL(request.url);
    const code = searchParams.get('code');
    const state = searchParams.get('state');
    const error = searchParams.get('error');

    console.log("📋 OAuth Parameters:", {
      hasCode: !!code,
      hasState: !!state,
      error: error || 'none'
    });

    // Handle OAuth errors from Google
    if (error) {
      console.log("❌ OAuth Error from Google:", error);
      const frontendUrl = new URL('/auth/callback', 'https://app.earnlayerai.com');
      frontendUrl.searchParams.set('error', error);
      return NextResponse.redirect(frontendUrl);
    }

    // Validate required parameters
    if (!code) {
      console.log("❌ Missing authorization code");
      const frontendUrl = new URL('/auth/callback', 'https://app.earnlayerai.com');
      frontendUrl.searchParams.set('error', 'missing_code');
      return NextResponse.redirect(frontendUrl);
    }

    if (!state) {
      console.log("❌ Missing state parameter");
      const frontendUrl = new URL('/auth/callback', 'https://app.earnlayerai.com');
      frontendUrl.searchParams.set('error', 'missing_state');
      return NextResponse.redirect(frontendUrl);
    }

    // Redirect to frontend callback page with OAuth parameters
    console.log("✅ Redirecting to frontend with OAuth parameters");
    const frontendUrl = new URL('/auth/callback', 'https://app.earnlayerai.com');
    frontendUrl.searchParams.set('code', code);
    frontendUrl.searchParams.set('state', state);

    return NextResponse.redirect(frontendUrl);

  } catch (error) {
    console.error("❌ OAuth Callback Error:", error);
    const frontendUrl = new URL('/auth/callback', 'https://app.earnlayerai.com');
    frontendUrl.searchParams.set('error', 'server_error');
    return NextResponse.redirect(frontendUrl);
  }
}