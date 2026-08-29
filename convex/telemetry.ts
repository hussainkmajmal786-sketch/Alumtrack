import { v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { Doc, Id } from "./_generated/dataModel";
import {
  distanceAlongM,
  etaSeconds,
  matchToRoute,
  parseClock,
} from "./lib/geo";

/**
 * A fix further than this from the route polyline is treated as spurious —
 * a cold-start GPS fix, a reflection in a built-up area, or a rider who is
 * no longer on the bus — and is stored but not used to move the bus.
 */
const MAX_OFF_ROUTE_M = 450;

/** A live fix older than this means the bus has effectively gone dark. */
export const STALE_AFTER_MS = 90_000;

/** Rider fixes are only trusted while the device feed is missing or stale. */
const DEVICE_PRIORITY_MS = 45_000;

/** Local timezone offset for schedule comparisons (IST). */
const TZ_OFFSET_MINUTES = Number(process.env.SCHEDULE_TZ_OFFSET_MINUTES ?? 330);

function secondsSinceLocalMidnight(epochMs: number): number {
  const shifted = epochMs + TZ_OFFSET_MINUTES * 60_000;
  return Math.floor((shifted % 86_400_000) / 1000);
}

export type IngestArgs = {
  routeId: Id<"routes">;
  lat: number;
  lng: number;
  speedKph?: number;
  headingDeg?: number;
  accuracyM?: number;
  satellites?: number;
  recordedAt: number;
  source: "device" | "rider";
  deviceId?: string;
  riderId?: string;
};

/**
 * Records a fix and refreshes the route's consolidated live state.
 *
 * Internal: all external entry points (HTTP ingest, rider sharing) validate
 * their caller first and then delegate here.
 */
export const ingest = internalMutation({
  args: {
    routeId: v.id("routes"),
    lat: v.number(),
    lng: v.number(),
    speedKph: v.optional(v.number()),
    headingDeg: v.optional(v.number()),
    accuracyM: v.optional(v.number()),
    satellites: v.optional(v.number()),
    recordedAt: v.number(),
    source: v.union(v.literal("device"), v.literal("rider")),
    deviceId: v.optional(v.string()),
    riderId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    await ctx.db.insert("positions", args);

    const stops = await ctx.db
      .query("stops")
      .withIndex("by_route_seq", (q) => q.eq("routeId", args.routeId))
      .collect();
    stops.sort((a, b) => a.seq - b.seq);
    if (stops.length < 2) return { accepted: false, reason: "route-has-no-geometry" };

    const match = matchToRoute(
      { lat: args.lat, lng: args.lng },
      stops.map((s) => ({ lat: s.lat, lng: s.lng })),
    );
    if (!match) return { accepted: false, reason: "route-has-no-geometry" };

    if (match.offRouteM > MAX_OFF_ROUTE_M) {
      return { accepted: false, reason: "off-route", offRouteM: match.offRouteM };
    }

    const existing = await ctx.db
      .query("liveState")
      .withIndex("by_route", (q) => q.eq("routeId", args.routeId))
      .unique();

    const now = Date.now();

    // The onboard device is authoritative. A rider fix only takes over once
    // the device has been quiet long enough to be considered degraded.
    if (
      args.source === "rider" &&
      existing?.source === "device" &&
      now - existing.updatedAt < DEVICE_PRIORITY_MS
    ) {
      return { accepted: true, applied: false, reason: "device-feed-is-fresher" };
    }

    const nextStop = stops[match.nextStopIndex];
    const remainingToNextM = distanceAlongM(
      stops.map((s) => ({ lat: s.lat, lng: s.lng })),
      match.progress,
      match.nextStopIndex,
    );
    const eta = etaSeconds(remainingToNextM, args.speedKph);

    // Delay is measured against the next stop's scheduled time: where we
    // predict arriving versus when the timetable says we should.
    let delaySeconds: number | undefined;
    const scheduled = parseClock(nextStop.scheduledAt);
    if (scheduled !== null) {
      const predictedArrival = secondsSinceLocalMidnight(now) + eta;
      let diff = predictedArrival - scheduled;
      // Fold day wrap-around (e.g. predicting 00:05 against a 23:50 schedule).
      if (diff > 43_200) diff -= 86_400;
      if (diff < -43_200) diff += 86_400;
      delaySeconds = diff;
    }

    const next = {
      routeId: args.routeId,
      lat: args.lat,
      lng: args.lng,
      speedKph: args.speedKph,
      headingDeg: args.headingDeg,
      progress: match.progress,
      nextStopSeq: nextStop.seq,
      etaSeconds: eta,
      delaySeconds,
      updatedAt: now,
      source: args.source,
      accuracyM: args.accuracyM,
    };

    if (existing) {
      await ctx.db.patch(existing._id, next);
    } else {
      await ctx.db.insert("liveState", next);
    }

    return { accepted: true, applied: true, progress: match.progress, etaSeconds: eta };
  },
});

/**
 * Rider-assisted fix. Requires an active share for that rider on that route,
 * so a client cannot move a bus simply by knowing its route id.
 */
export const submitRiderFix = mutation({
  args: {
    routeId: v.id("routes"),
    riderId: v.string(),
    lat: v.number(),
    lng: v.number(),
    speedKph: v.optional(v.number()),
    headingDeg: v.optional(v.number()),
    accuracyM: v.optional(v.number()),
    recordedAt: v.number(),
  },
  handler: async (ctx, args) => {
    const share = await ctx.db
      .query("riderShares")
      .withIndex("by_riderId", (q) => q.eq("riderId", args.riderId))
      .unique();

    if (!share || !share.active || share.routeId !== args.routeId) {
      throw new Error("No active location share for this rider on this route");
    }

    await ctx.db.patch(share._id, { lastSeen: Date.now() });

    return await ctx.runMutation(internal.telemetry.ingest, {
      routeId: args.routeId,
      lat: args.lat,
      lng: args.lng,
      speedKph: args.speedKph,
      headingDeg: args.headingDeg,
      accuracyM: args.accuracyM,
      recordedAt: args.recordedAt,
      source: "rider" as const,
      riderId: args.riderId,
    });
  },
});

/** Signal quality derived from how fresh and how precise the live fix is. */
export type SignalQuality = "good" | "weak" | "offline";

export function signalQuality(
  live: Doc<"liveState"> | null,
  now: number,
): SignalQuality {
  if (!live) return "offline";
  const age = now - live.updatedAt;
  if (age > STALE_AFTER_MS) return "offline";
  // A rider-sourced fix means the onboard unit already went quiet, and a
  // low-accuracy fix is not worth presenting as precise.
  if (live.source === "rider") return "weak";
  if (live.accuracyM !== undefined && live.accuracyM > 75) return "weak";
  if (age > STALE_AFTER_MS / 2) return "weak";
  return "good";
}

/** Recent raw fixes for a route — used for debugging and admin views. */
export const recentPositions = query({
  args: {
    routeId: v.id("routes"),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = Math.min(args.limit ?? 50, 200);
    return await ctx.db
      .query("positions")
      .withIndex("by_route_recordedAt", (q) => q.eq("routeId", args.routeId))
      .order("desc")
      .take(limit);
  },
});
