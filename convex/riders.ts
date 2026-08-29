import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import { STALE_AFTER_MS } from "./telemetry";

/**
 * Starts or stops a rider's location share.
 *
 * A rider has at most one share at a time; switching routes moves it rather
 * than accumulating rows.
 */
export const setSharing = internalMutation({
  args: {
    riderId: v.string(),
    routeId: v.id("routes"),
    active: v.boolean(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const existing = await ctx.db
      .query("riderShares")
      .withIndex("by_riderId", (q) => q.eq("riderId", args.riderId))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        routeId: args.routeId,
        active: args.active,
        lastSeen: now,
        ...(args.active && !existing.active ? { startedAt: now } : {}),
      });
    } else if (args.active) {
      await ctx.db.insert("riderShares", {
        riderId: args.riderId,
        routeId: args.routeId,
        startedAt: now,
        lastSeen: now,
        active: true,
      });
    }

    return { active: args.active, count: await countActive(ctx, args.routeId) };
  },
});

async function countActive(ctx: any, routeId: Doc<"routes">["_id"]) {
  const shares = await ctx.db
    .query("riderShares")
    .withIndex("by_route_active", (q: any) =>
      q.eq("routeId", routeId).eq("active", true),
    )
    .collect();
  const cutoff = Date.now() - STALE_AFTER_MS;
  return shares.filter((s: Doc<"riderShares">) => s.lastSeen >= cutoff).length;
}

export const sharingState = internalQuery({
  args: { riderId: v.string(), routeId: v.id("routes") },
  handler: async (ctx, args) => {
    const share = await ctx.db
      .query("riderShares")
      .withIndex("by_riderId", (q) => q.eq("riderId", args.riderId))
      .unique();

    const active =
      !!share &&
      share.active &&
      share.routeId === args.routeId &&
      Date.now() - share.lastSeen < STALE_AFTER_MS;

    return { active, count: await countActive(ctx, args.routeId) };
  },
});

/**
 * Marks shares that stopped reporting as inactive.
 *
 * Phones go to sleep and browsers get closed without a clean stop, so the
 * count would otherwise drift upward forever. Run from a cron.
 */
export const expireStaleShares = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - STALE_AFTER_MS;
    const shares = await ctx.db.query("riderShares").collect();
    let expired = 0;
    for (const s of shares) {
      if (s.active && s.lastSeen < cutoff) {
        await ctx.db.patch(s._id, { active: false });
        expired++;
      }
    }
    return { expired };
  },
});
