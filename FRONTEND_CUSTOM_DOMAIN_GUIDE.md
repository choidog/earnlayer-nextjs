# Frontend Custom Domain Setup Guide

## 🎯 **Overview**
With the new custom domain setup, authentication will now work with privacy browsers (Brave with shields, Safari, Firefox strict mode) because both frontend and backend share the same root domain.

**New Setup:**
- Frontend: `https://app.earnlayerai.com`
- Backend: `https://api.earnlayerai.com`
- Shared root domain: `earnlayerai.com` (enables first-party cookies)

## 🔧 **Required Frontend Changes**

### **1. Update Environment Variables**

Update your frontend environment variables (in Vercel dashboard or `.env.production`):

```bash
# OLD VALUES (remove these)
NEXT_PUBLIC_BETTER_AUTH_URL=https://web-production-f8de.up.railway.app

# NEW VALUES (add these)
NEXT_PUBLIC_BETTER_AUTH_URL=https://api.earnlayerai.com
```

### **2. Update Vercel Custom Domain**

In your Vercel dashboard:
1. Go to **Settings** → **Domains**
2. Add custom domain: `app.earnlayerai.com`
3. Configure DNS with these records in your domain registrar:

```
Type: CNAME
Name: app
Value: cname.vercel-dns.com
```

### **3. Update Google OAuth Console**

In Google Cloud Console, update your OAuth 2.0 Client:

**Authorized JavaScript origins:**
```
https://app.earnlayerai.com
```

**Authorized redirect URIs:**
```
https://api.earnlayerai.com/api/auth/callback/google
```

### **4. Test Authentication Flow**

After deploying:
1. Go to `https://app.earnlayerai.com`
2. Click "Continue with Google"
3. Complete OAuth flow
4. **Should work with Brave shields enabled!** ✅

## 🔍 **Why This Fixes Privacy Browser Issues**

**Before (Cross-Origin):**
- Frontend: `earnlayer-chat-nextjs.vercel.app` 
- Backend: `web-production-f8de.up.railway.app`
- Different domains = third-party cookies = blocked by privacy browsers

**After (Same Root Domain):**
- Frontend: `app.earnlayerai.com`
- Backend: `api.earnlayerai.com`
- Same root domain = first-party cookies = allowed by all browsers

## 🚨 **Backend Changes Already Complete**

The backend has been updated with:
- ✅ CORS configured for `https://app.earnlayerai.com`
- ✅ Cookie domain set to `.earnlayerai.com` (subdomain sharing)
- ✅ SameSite changed from `none` to `lax` (more compatible)
- ✅ Environment variables updated to use `api.earnlayerai.com`

## 📋 **Deployment Checklist**

### **Frontend Team Actions:**
- [ ] Update `NEXT_PUBLIC_BETTER_AUTH_URL` environment variable
- [ ] Add custom domain `app.earnlayerai.com` in Vercel
- [ ] Configure DNS CNAME record: `app → cname.vercel-dns.com`
- [ ] Deploy frontend changes
- [ ] Update Google OAuth console settings

### **Domain Configuration:**
- [ ] Set up `app.earnlayerai.com` → Vercel
- [ ] Set up `api.earnlayerai.com` → Railway (already done)
- [ ] Wait for DNS propagation (5-15 minutes)

### **Testing:**
- [ ] Test with regular browser
- [ ] Test with Brave shields enabled
- [ ] Test with Safari strict mode
- [ ] Test with Firefox enhanced tracking protection

## 🎉 **Expected Result**

Authentication will work across all privacy-focused browsers without requiring users to disable privacy features. Users will see a seamless Google OAuth experience on your custom branded domain.

## 🔧 **Troubleshooting**

**If authentication still doesn't work:**

1. **Check DNS propagation**: Use `dig app.earnlayerai.com` and `dig api.earnlayerai.com`
2. **Clear browser cache**: Both domains need fresh DNS resolution
3. **Check Google OAuth console**: Ensure redirect URIs are exactly `https://api.earnlayerai.com/api/auth/callback/google`
4. **Verify environment variables**: `NEXT_PUBLIC_BETTER_AUTH_URL=https://api.earnlayerai.com`

**If you see CORS errors:**
- Ensure frontend is deployed to `app.earnlayerai.com` (not the old Vercel domain)
- Backend CORS is configured for the new frontend domain

## 📞 **Support**

If you encounter issues:
1. Check browser developer console for errors
2. Verify DNS records are correctly pointing to Vercel/Railway
3. Confirm both domains are using HTTPS certificates
4. Test authentication flow in incognito/private browsing mode

---

**This setup provides the best user experience across all browsers while maintaining security and privacy compliance.** 🚀