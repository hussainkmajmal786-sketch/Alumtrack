import { v } from "convex/values";
import { internalMutation, internalQuery, query } from "./_generated/server";
import { sha256Hex } from "./lib/auth";

const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 60; // 60 days

/** Resolves a bearer token to its subject, or null when invalid/expired. */
export const subjectForToken = internalQuery({
  args: { token: v.string() },
  handler: async (ctx, args) => {
    const hash = await sha256Hex(args.token);
    const session = await ctx.db
      .query("sessions")
      .withIndex("by_tokenHash", (q) => q.eq("tokenHash", hash))
      .unique();
    if (!session) return null;
    if (session.expiresAt < Date.now()) return null;
    return session.subject;
  },
});

/**
 * Creates or refreshes a user and issues a session.
 *
 * `tokenHash` is computed by the caller (an HTTP action) so the plaintext
 * token never enters the database.
 */
export const upsertAndIssueSession = internalMutation({
  args: {
    subject: v.string(),
    email: v.optional(v.string()),
    name: v.optional(v.string()),
    pictureUrl: v.optional(v.string()),
    isGuest: v.boolean(),
    tokenHash: v.string(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();

    const existing = await ctx.db
      .query("users")
      .withIndex("by_subject", (q) => q.eq("subject", args.subject))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        email: args.email ?? existing.email,
        name: args.name ?? existing.name,
        pictureUrl: args.pictureUrl ?? existing.pictureUrl,
        lastSeenAt: now,
      });
    } else {
      await ctx.db.insert("users", {
        subject: args.subject,
        email: args.email,
        name: args.name,
        pictureUrl: args.pictureUrl,
        isGuest: args.isGuest,
        notifyLeadMinutes: 5,
        createdAt: now,
        lastSeenAt: now,
      });
    }

    // Drop expired sessions for this subject so the table does not grow
    // without bound for long-lived users.
    const stale = await ctx.db
      .query("sessions")
      .withIndex("by_subject", (q) => q.eq("subject", args.subject))
      .collect();
    for (const s of stale) {
      if (s.expiresAt < now) await ctx.db.delete(s._id);
    }

    await ctx.db.insert("sessions", {
      tokenHash: args.tokenHash,
      subject: args.subject,
      createdAt: now,
      expiresAt: now + SESSION_TTL_MS,
    });

    return { subject: args.subject, expiresAt: now + SESSION_TTL_MS };
  },
});

export const profileFor = internalQuery({
  args: { subject: v.string() },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("users")
      .withIndex("by_subject", (q) => q.eq("subject", args.subject))
      .unique();
    if (!user) return null;

    const route = user.linkedRouteId ? await ctx.db.get(user.linkedRouteId) : null;

    return {
      subject: user.subject,
      email: user.email ?? null,
      name: user.name ?? null,
      pictureUrl: user.pictureUrl ?? null,
      isGuest: user.isGuest,
      notifyLeadMinutes: user.notifyLeadMinutes,
      linkedRoute: route
        ? { id: route._id, number: route.number, name: route.name }
        : null,
    };
  },
});

export const updatePreferences = internalMutation({
  args: {
    subject: v.string(),
    notifyLeadMinutes: v.optional(v.number()),
    linkedRouteId: v.optional(v.id("routes")),
  },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("users")
      .withIndex("by_subject", (q) => q.eq("subject", args.subject))
      .unique();
    if (!user) throw new Error("Unknown user");

    const patch: Record<string, unknown> = { lastSeenAt: Date.now() };
    if (args.notifyLeadMinutes !== undefined) {
      if (![2, 5, 10].includes(args.notifyLeadMinutes)) {
        throw new Error("notifyLeadMinutes must be 2, 5 or 10");
      }
      patch.notifyLeadMinutes = args.notifyLeadMinutes;
    }
    if (args.linkedRouteId !== undefined) patch.linkedRouteId = args.linkedRouteId;

    await ctx.db.patch(user._id, patch);
    return { ok: true };
  },
});

export const signOut = internalMutation({
  args: { tokenHash: v.string() },
  handler: async (ctx, args) => {
    const session = await ctx.db
      .query("sessions")
      .withIndex("by_tokenHash", (q) => q.eq("tokenHash", args.tokenHash))
      .unique();
    if (session) await ctx.db.delete(session._id);
    return { ok: true };
  },
});

/** Count of routes, for the "N routes" subtitle on the list screen. */
export const routeCount = query({
  args: {},
  handler: async (ctx) => {
    const routes = await ctx.db.query("routes").collect();
    return routes.filter((r) => r.active).length;
  },
});
