/**
 * Response helpers and auth middleware, ported from convex/http.ts.
 *
 * The response shapes are deliberately byte-identical to the Convex ones:
 * the Flutter client parses these today, and the migration is meant to be
 * invisible to it beyond a change of base URL.
 */

import type { Context, Next } from "hono";
import { bearerToken, sha256Hex } from "./auth";
import { one, type AdminRow, type Env, type SessionRow } from "./db";

export type AppContext = Context<{
  Bindings: Env;
  Variables: { subject?: string; admin?: AdminSummary };
}>;

export type AdminRole = "admin" | "superadmin";

export interface AdminSummary {
  id: string;
  role: AdminRole;
  name: string;
  email: string;
}

/**
 * Browsers enforce CORS on the Flutter web build. ALLOWED_ORIGIN is set to
 * the deployed web origin in production; the default stays permissive so a
 * local `flutter run -d chrome` (random port) works without reconfiguring.
 */
export function corsHeaders(env: Env): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": env.ALLOWED_ORIGIN ?? "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

export function json(c: AppContext, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(c.env) },
  });
}

export function fail(c: AppContext, message: string, status: number): Response {
  return json(c, { error: message }, status);
}

/**
 * Resolves a bearer token to its subject, rejecting expired sessions.
 *
 * Mirrors `users.subjectForToken`: only the token's hash is stored, so the
 * lookup hashes the presented token rather than comparing plaintext.
 */
export async function subjectForToken(
  env: Env,
  token: string,
): Promise<string | null> {
  const tokenHash = await sha256Hex(token);
  const session = await one<SessionRow>(
    env.DB.prepare("SELECT * FROM sessions WHERE tokenHash = ?").bind(tokenHash),
  );
  if (!session) return null;
  if (session.expiresAt < Date.now()) return null;
  return session.subject;
}

export async function requireSubject(c: AppContext): Promise<string | null> {
  const token = bearerToken(c.req.header("Authorization") ?? null);
  if (!token) return null;
  return subjectForToken(c.env, token);
}

/**
 * Resolves the caller to an admin record, or null.
 *
 * Admin sessions carry an `admin:<id>` subject, which is how a staff session
 * is told apart from a student one holding the same kind of bearer token.
 */
export async function requireAdmin(
  c: AppContext,
  minRole: AdminRole = "admin",
): Promise<AdminSummary | null> {
  const subject = await requireSubject(c);
  if (!subject || !subject.startsWith("admin:")) return null;

  const id = subject.slice("admin:".length);
  const admin = await one<AdminRow>(
    c.env.DB.prepare("SELECT * FROM admins WHERE id = ?").bind(id),
  );
  if (!admin || admin.active !== 1) return null;
  if (minRole === "superadmin" && admin.role !== "superadmin") return null;

  return { id: admin.id, role: admin.role, name: admin.name, email: admin.email };
}

/** Middleware: 401s unless the caller presents a valid student session. */
export async function withSubject(c: AppContext, next: Next) {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);
  c.set("subject", subject);
  await next();
}

/** Middleware: 401s unless the caller is an active admin. */
export async function withAdmin(c: AppContext, next: Next) {
  const admin = await requireAdmin(c);
  if (!admin) return fail(c, "Unauthorized", 401);
  c.set("admin", admin);
  await next();
}

/** Middleware: 401s unless the caller is a superadmin. */
export async function withSuperadmin(c: AppContext, next: Next) {
  const admin = await requireAdmin(c, "superadmin");
  if (!admin) return fail(c, "Unauthorized", 401);
  c.set("admin", admin);
  await next();
}

/** Parses a JSON body, returning null rather than throwing on bad input. */
export async function readJson(c: AppContext): Promise<any | null> {
  try {
    return await c.req.json();
  } catch {
    return null;
  }
}
