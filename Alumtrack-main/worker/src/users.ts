/**
 * User records, sessions and profiles, ported from convex/users.ts.
 *
 * Password hashes carry over untouched: lib/auth.ts is a verbatim copy of
 * the Convex original, so a PBKDF2 hash written by the old backend verifies
 * here without anyone needing to reset a password.
 */

import { hashPassword, sha256Hex, verifyPassword } from "./lib/auth";
import { newId, one, type Env, type RouteRow, type StopRow, type UserRow } from "./lib/db";

/** Sessions last two weeks, matching the Convex deployment. */
const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 14;

export async function issueSession(
  env: Env,
  subject: string,
  tokenHash: string,
): Promise<void> {
  const now = Date.now();
  await env.DB.prepare(
    "INSERT INTO sessions (id, tokenHash, subject, createdAt, expiresAt) VALUES (?, ?, ?, ?, ?)",
  )
    .bind(newId(), tokenHash, subject, now, now + SESSION_TTL_MS)
    .run();
}

/**
 * Creates the user if absent, refreshes their profile if present, and
 * issues a session either way.
 *
 * Google can change a display name or avatar between sign-ins, so those
 * fields are refreshed; `linkedRouteId` and preferences deliberately are
 * not, since those are the rider's (or an admin's) choices, not Google's.
 */
export async function upsertAndIssueSession(
  env: Env,
  args: {
    subject: string;
    email?: string;
    name?: string;
    pictureUrl?: string;
    isGuest: boolean;
    tokenHash: string;
  },
): Promise<void> {
  const now = Date.now();
  const existing = await one<UserRow>(
    env.DB.prepare("SELECT * FROM users WHERE subject = ?").bind(args.subject),
  );

  if (existing) {
    await env.DB.prepare(
      `UPDATE users
          SET email = COALESCE(?, email),
              name = COALESCE(?, name),
              pictureUrl = COALESCE(?, pictureUrl),
              lastSeenAt = ?
        WHERE subject = ?`,
    )
      .bind(args.email ?? null, args.name ?? null, args.pictureUrl ?? null, now, args.subject)
      .run();
  } else {
    await env.DB.prepare(
      `INSERT INTO users
         (id, subject, email, name, pictureUrl, isGuest, notifyLeadMinutes, createdAt, lastSeenAt)
       VALUES (?, ?, ?, ?, ?, ?, 5, ?, ?)`,
    )
      .bind(
        newId(),
        args.subject,
        args.email ?? null,
        args.name ?? null,
        args.pictureUrl ?? null,
        args.isGuest ? 1 : 0,
        now,
        now,
      )
      .run();
  }

  await issueSession(env, args.subject, args.tokenHash);
}

/**
 * Registers a student with an email and password.
 *
 * Throws rather than returning an error shape, so the caller maps it to a
 * 409 the same way the Convex handler did.
 */
export async function signUpWithPassword(
  env: Env,
  email: string,
  password: string,
  name?: string,
): Promise<{ subject: string }> {
  const normalised = email.trim().toLowerCase();
  const subject = `email:${normalised}`;

  const existing = await one<UserRow>(
    env.DB.prepare("SELECT id FROM users WHERE subject = ?").bind(subject),
  );
  if (existing) throw new Error("An account with that email already exists");

  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO users
       (id, subject, email, name, isGuest, passwordHash, notifyLeadMinutes, createdAt, lastSeenAt)
     VALUES (?, ?, ?, ?, 0, ?, 5, ?, ?)`,
  )
    .bind(newId(), subject, normalised, name ?? null, await hashPassword(password), now, now)
    .run();

  return { subject };
}

/** Verifies an email/password pair, returning the user's subject or null. */
export async function verifyStudentPassword(
  env: Env,
  email: string,
  password: string,
): Promise<{ subject: string } | null> {
  const subject = `email:${email.trim().toLowerCase()}`;
  const user = await one<UserRow>(
    env.DB.prepare("SELECT * FROM users WHERE subject = ?").bind(subject),
  );
  if (!user?.passwordHash) return null;
  if (!(await verifyPassword(password, user.passwordHash))) return null;
  return { subject: user.subject };
}

export async function signOut(env: Env, tokenHash: string): Promise<void> {
  await env.DB.prepare("DELETE FROM sessions WHERE tokenHash = ?").bind(tokenHash).run();
}

export interface Profile {
  subject: string;
  email: string | null;
  name: string | null;
  pictureUrl: string | null;
  isGuest: boolean;
  notifyLeadMinutes: number;
  linkedRoute: { id: string; number: string; name: string } | null;
  linkedStop: { id: string; name: string; seq: number } | null;
}

export async function profileFor(env: Env, subject: string): Promise<Profile | null> {
  const user = await one<UserRow>(
    env.DB.prepare("SELECT * FROM users WHERE subject = ?").bind(subject),
  );
  if (!user) return null;

  const route = user.linkedRouteId
    ? await one<RouteRow>(
        env.DB.prepare("SELECT id, number, name FROM routes WHERE id = ?").bind(user.linkedRouteId),
      )
    : null;
  const stop = user.linkedStopId
    ? await one<StopRow>(
        env.DB.prepare("SELECT id, name, seq FROM stops WHERE id = ?").bind(user.linkedStopId),
      )
    : null;

  return {
    subject: user.subject,
    email: user.email,
    name: user.name,
    pictureUrl: user.pictureUrl,
    isGuest: user.isGuest === 1,
    notifyLeadMinutes: user.notifyLeadMinutes,
    linkedRoute: route ? { id: route.id, number: route.number, name: route.name } : null,
    linkedStop: stop ? { id: stop.id, name: stop.name, seq: stop.seq } : null,
  };
}

export async function updatePreferences(
  env: Env,
  subject: string,
  args: { notifyLeadMinutes?: number; linkedRouteId?: string | null },
): Promise<void> {
  const user = await one<UserRow>(
    env.DB.prepare("SELECT id FROM users WHERE subject = ?").bind(subject),
  );
  if (!user) throw new Error("Unknown user");

  if (args.notifyLeadMinutes !== undefined) {
    if (![2, 5, 10].includes(args.notifyLeadMinutes)) {
      throw new Error("notifyLeadMinutes must be 2, 5 or 10");
    }
    await env.DB.prepare("UPDATE users SET notifyLeadMinutes = ? WHERE id = ?")
      .bind(args.notifyLeadMinutes, user.id)
      .run();
  }

  if (args.linkedRouteId !== undefined) {
    // A pinned stop only means anything within its own route, so changing
    // the route clears it rather than leaving it pointing at a stop on a
    // bus the rider is no longer on.
    await env.DB.prepare("UPDATE users SET linkedRouteId = ?, linkedStopId = NULL WHERE id = ?")
      .bind(args.linkedRouteId, user.id)
      .run();
  }

  await env.DB.prepare("UPDATE users SET lastSeenAt = ? WHERE id = ?")
    .bind(Date.now(), user.id)
    .run();
}

/** Verifies a Google ID token against the configured client ids. */
export async function verifyGoogleIdToken(
  env: Env,
  idToken: string,
): Promise<{ ok: true; claims: any } | { ok: false; status: number; message: string }> {
  const clientIds = (env.GOOGLE_CLIENT_IDS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (clientIds.length === 0) {
    return { ok: false, status: 503, message: "GOOGLE_CLIENT_IDS is not configured on the backend" };
  }

  const res = await fetch(
    `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(idToken)}`,
  );
  if (!res.ok) return { ok: false, status: 401, message: "Google rejected the ID token" };

  const claims: any = await res.json();
  if (!clientIds.includes(claims.aud)) {
    return { ok: false, status: 401, message: "ID token was issued for a different client" };
  }
  if (claims.iss !== "accounts.google.com" && claims.iss !== "https://accounts.google.com") {
    return { ok: false, status: 401, message: "Unexpected token issuer" };
  }
  if (Number(claims.exp) * 1000 < Date.now()) {
    return { ok: false, status: 401, message: "ID token has expired" };
  }

  return { ok: true, claims };
}

/** Verifies admin credentials, returning the admin row or null. */
export async function verifyAdminCredentials(env: Env, email: string, password: string) {
  const normalised = email.trim().toLowerCase();
  const admin = await one<{
    id: string;
    passwordHash: string;
    role: "admin" | "superadmin";
    name: string;
    email: string;
    active: number;
  }>(env.DB.prepare("SELECT * FROM admins WHERE email = ?").bind(normalised));

  if (!admin || admin.active !== 1) return null;
  if (!(await verifyPassword(password, admin.passwordHash))) return null;
  return { id: admin.id, role: admin.role, name: admin.name, email: admin.email };
}

export { sha256Hex };
