import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";

const PAGE_SIZE = 60;

/** Alerts relevant to a subject: broadcasts plus their linked route. */
export const feedFor = internalQuery({
  args: { subject: v.string() },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("users")
      .withIndex("by_subject", (q) => q.eq("subject", args.subject))
      .unique();

    const all = await ctx.db
      .query("alerts")
      .withIndex("by_createdAt")
      .order("desc")
      .take(PAGE_SIZE);

    const linked = user?.linkedRouteId ?? null;
    const relevant = all.filter(
      (a) => a.routeId === undefined || a.routeId === linked,
    );

    const read = await ctx.db
      .query("alertReads")
      .withIndex("by_subject", (q) => q.eq("subject", args.subject))
      .unique();
    const readThrough = read?.readThrough ?? 0;

    return {
      unread: relevant.filter((a) => a.createdAt > readThrough).length,
      items: relevant.map((a) => ({
        id: a._id,
        kind: a.kind,
        message: a.message,
        createdAt: a.createdAt,
        unread: a.createdAt > readThrough,
        routeNumber: a.routeNumber ?? null,
      })),
    };
  },
});

export const markRead = internalMutation({
  args: { subject: v.string() },
  handler: async (ctx, args) => {
    const now = Date.now();
    const existing = await ctx.db
      .query("alertReads")
      .withIndex("by_subject", (q) => q.eq("subject", args.subject))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, { readThrough: now });
    } else {
      await ctx.db.insert("alertReads", { subject: args.subject, readThrough: now });
    }
    return { ok: true };
  },
});

export const publish = internalMutation({
  args: {
    routeId: v.optional(v.id("routes")),
    kind: v.union(
      v.literal("arriving"),
      v.literal("delay"),
      v.literal("signal"),
      v.literal("service"),
    ),
    message: v.string(),
  },
  handler: async (ctx, args) => {
    let routeNumber: string | undefined;
    if (args.routeId) {
      const route = await ctx.db.get<"routes">(args.routeId);
      routeNumber = route?.number;
    }
    return await ctx.db.insert("alerts", {
      ...args,
      routeNumber,
      createdAt: Date.now(),
    });
  },
});
