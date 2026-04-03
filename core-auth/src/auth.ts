import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins";
import { pool } from "./db";

const CORE_API_URL = process.env.CORE_API_URL || "http://localhost:8000";
const INTERNAL_API_SECRET = process.env.INTERNAL_API_SECRET || "";
const FRONTEND_URL = process.env.FRONTEND_URL || "http://localhost:5173";

export const auth = betterAuth({
  database: pool,

  // ── Email & Password ────────────────────────────────────────────────────────
  emailAndPassword: {
    enabled: true,
    minPasswordLength: 12,
    maxPasswordLength: 256,
    // Revoke all sessions when user resets password — security best practice
    revokeSessionsOnPasswordReset: true,
    sendResetPassword: async ({ user, url }) => {
      // TODO: replace console.log with Resend email sending
      // import { Resend } from "resend";
      // const resend = new Resend(process.env.RESEND_API_KEY);
      // await resend.emails.send({ to: user.email, subject: "Reset your password", html: `<a href="${url}">Reset password</a>` });
      console.log(`[auth] Password reset requested for ${user.email}: ${url}`);
    },
  },

  // ── Email Verification ───────────────────────────────────────────────────────
  emailVerification: {
    // Set requireEmailVerification: true in production for stricter security
    sendVerificationEmail: async ({ user, url }) => {
      // TODO: replace with Resend
      console.log(`[auth] Verify email for ${user.email}: ${url}`);
    },
  },

  // ── Plugins ──────────────────────────────────────────────────────────────────
  plugins: [
    // bearer() enables Authorization: Bearer <session_token> header support
    // so the React frontend can send session tokens to both core-auth and core-api
    bearer(),
  ],

  // ── Session ──────────────────────────────────────────────────────────────────
  session: {
    expiresIn: 60 * 60 * 24 * 7,   // 7 days
    updateAge: 60 * 60 * 24,         // refresh session daily on activity
    cookieCache: {
      enabled: true,
      maxAge: 60 * 5,               // 5-minute client-side cookie cache
    },
  },

  // ── Security ─────────────────────────────────────────────────────────────────
  advanced: {
    useSecureCookies: process.env.NODE_ENV === "production",
    database: {
      // Generate proper UUIDs — compatible with the app's uuid columns
      generateId: () => crypto.randomUUID(),
    },
  },

  trustedOrigins: [FRONTEND_URL],

  // ── User provisioning hook ───────────────────────────────────────────────────
  // After better-auth creates a user, call core-api to:
  //   1. Insert into public.users (app user profile)
  //   2. Create a default "Personal" workspace via create_workspace_with_defaults()
  //
  // This replaces the Supabase DB trigger on auth.users INSERT.
  databaseHooks: {
    user: {
      create: {
        after: async (user) => {
          try {
            const response = await fetch(`${CORE_API_URL}/api/init/new-user`, {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "X-Internal-Secret": INTERNAL_API_SECRET,
              },
              body: JSON.stringify({
                user_id: user.id,
                email: user.email,
                name: user.name,
              }),
            });

            if (!response.ok) {
              const body = await response.text();
              console.error(`[auth] Failed to provision user ${user.id}: ${response.status} ${body}`);
            } else {
              console.log(`[auth] Provisioned user ${user.id} (${user.email})`);
            }
          } catch (err) {
            // Log but don't throw — user is created in better-auth regardless.
            // The workspace can be created lazily on first login if needed.
            console.error(`[auth] Error provisioning user ${user.id}:`, err);
          }
        },
      },
    },
  },
});
