import { Hono } from "hono";
import { cors } from "hono/cors";
import { auth } from "./auth";

const FRONTEND_URL = process.env.FRONTEND_URL || "http://localhost:5173";
const PORT = parseInt(process.env.PORT || "3001", 10);

const app = new Hono();

// CORS — allow both cookie-based requests from the browser and
// bearer-token-based requests from core-api or CLI clients
app.use(
  "*",
  cors({
    origin: [FRONTEND_URL],
    allowHeaders: ["Content-Type", "Authorization", "X-Internal-Secret"],
    allowMethods: ["GET", "POST", "DELETE", "OPTIONS", "PUT", "PATCH"],
    credentials: true,
    maxAge: 600,
  })
);

// Mount all better-auth routes at /api/auth/**
// This exposes endpoints like:
//   POST /api/auth/sign-up/email
//   POST /api/auth/sign-in/email
//   POST /api/auth/sign-out
//   GET  /api/auth/get-session
//   POST /api/auth/forget-password
//   POST /api/auth/reset-password
//   GET  /api/auth/ok  (health check)
app.on(["GET", "POST", "DELETE", "PUT", "PATCH"], "/api/auth/**", (c) =>
  auth.handler(c.req.raw)
);

// Health check (independent of better-auth)
app.get("/health", (c) => c.json({ status: "ok", service: "core-auth" }));

console.log(`[core-auth] Starting on port ${PORT}`);
console.log(`[core-auth] FRONTEND_URL: ${FRONTEND_URL}`);
console.log(`[core-auth] NODE_ENV: ${process.env.NODE_ENV || "development"}`);

export default {
  port: PORT,
  fetch: app.fetch,
};
