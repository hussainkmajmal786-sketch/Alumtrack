import { v } from "convex/values";
import { query } from "./_generated/server";
import { Doc, Id } from "./_generated/dataModel";
import { signalQuality, STALE_AFTER_MS } from "./telemetry";

/** Presentation status for a route row, mirroring the design's status pills. */
export type RouteStatus = "onTime" | "late" | "weak" | "offline";

/** Late by more than this is worth calling out to riders. */
const LATE_THRESHOLD_S = 120;

function statusFor(
  live: Doc<"liveState"> | null,
  now: number,
): RouteStatus {
  const quality = signalQuality(live, now);
  if (quality === "offline") return "offline";
  if (quality === "weak") return "weak";
  if (live?.delaySeconds !== undefined && live.delaySeconds > LATE_THRESHOLD_S) {
    return "late";
  }
  return "onTime";
}

async function liveFor(ctx: any, routeId: Id<"routes">) {
  return await ctx.db
    .query("liveState")
    .withIndex("by_route", (q: any) => q.eq("routeId", routeId))
    .unique();
}

async function activeRiderCount(ctx: any, routeId: Id<"routes">) {
  const shares = await ctx.db
    .query("riderShares")
    .withIndex("by_route_active", (q: any) =>
      q.eq("routeId", routeId).eq("active", true),
    )
    .collect();
  const cutoff = Date.now() - STALE_AFTER_MS;
  return shares.filter((s: Doc<"riderShares">) => s.lastSeen >= cutoff).length;
}

/** Every active route with its current status — backs the Buses list. */
export const list = query({
  args: {},
  handler: async (ctx) => {
    const routes = await ctx.db.query("routes").collect();
    const now = Date.now();

    const rows = await Promise.all(
      routes
        .filter((r) => r.active)
        .map(async (route) => {
          const live = await liveFor(ctx, route._id);
          const status = statusFor(live, now);
          return {
            id: route._id,
            number: route.number,
            name: route.name,
            status,
            etaSeconds:
              status === "offline" ? null : (live?.etaSeconds ?? null),
            delaySeconds: live?.delaySeconds ?? null,
            updatedAt: live?.updatedAt ?? null,
          };
        }),
    );

    rows.sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true }));
    return { routes: rows, serverNow: now };
  },
});

/** Full detail for one route — backs the Live status screen. */
export const detail = query({
  args: { routeId: v.id("routes") },
  handler: async (ctx, args) => {
    const route = await ctx.db.get(args.routeId);
    if (!route) return null;

    const stops = await ctx.db
      .query("stops")
      .withIndex("by_route_seq", (q) => q.eq("routeId", args.routeId))
      .collect();
    stops.sort((a, b) => a.seq - b.seq);

    const live = await liveFor(ctx, args.routeId);
    const now = Date.now();
    const status = statusFor(live, now);
    const riders = await activeRiderCount(ctx, args.routeId);

    const nextSeq = live?.nextStopSeq ?? 0;

    return {
      id: route._id,
      number: route.number,
      name: route.name,
      scheduledArrival: route.scheduledArrival ?? null,
      status,
      riders,
      signal: signalQuality(live, now),
      live: live
        ? {
            lat: live.lat,
            lng: live.lng,
            progress: live.progress,
            speedKph: live.speedKph ?? null,
            headingDeg: live.headingDeg ?? null,
            etaSeconds: live.etaSeconds ?? null,
            delaySeconds: live.delaySeconds ?? null,
            updatedAt: live.updatedAt,
            source: live.source,
            stale: now - live.updatedAt > STALE_AFTER_MS,
          }
        : null,
      stops: stops.map((s) => ({
        seq: s.seq,
        name: s.name,
        lat: s.lat,
        lng: s.lng,
        scheduledAt: s.scheduledAt ?? null,
        state:
          s.seq < nextSeq ? "past" : s.seq === nextSeq ? "next" : "ahead",
      })),
      serverNow: now,
    };
  },
});

/** Stop coordinates only — enough to draw the polyline before live data lands. */
export const geometry = query({
  args: { routeId: v.id("routes") },
  handler: async (ctx, args) => {
    const stops = await ctx.db
      .query("stops")
      .withIndex("by_route_seq", (q) => q.eq("routeId", args.routeId))
      .collect();
    stops.sort((a, b) => a.seq - b.seq);
    return stops.map((s) => ({ seq: s.seq, name: s.name, lat: s.lat, lng: s.lng }));
  },
});
