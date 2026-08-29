import { internalMutation } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import { signalQuality, STALE_AFTER_MS } from "./telemetry";

const POSITION_RETENTION_MS = 1000 * 60 * 60 * 24 * 7; // 7 days
const PRUNE_BATCH = 400;

/** Don't re-announce the same condition on every tick. */
const ALERT_COOLDOWN_MS = 1000 * 60 * 20;
const LATE_THRESHOLD_S = 120;

function minutes(seconds: number): number {
  return Math.max(1, Math.round(seconds / 60));
}

/**
 * Derives rider-facing alerts from live state.
 *
 * Runs on a cron rather than on ingest so a bus reporting at 1 Hz cannot
 * spam the alert feed.
 */
export const generateAlerts = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const routes = await ctx.db.query("routes").collect();
    let published = 0;

    // Read once: the arrival check below needs every user's lead-time
    // preference, and re-reading per route would scan the table N times.
    const users = await ctx.db.query("users").collect();
    const leadsByRoute = new Map<string, Set<number>>();
    for (const u of users) {
      if (!u.linkedRouteId) continue;
      const set = leadsByRoute.get(u.linkedRouteId) ?? new Set<number>();
      set.add(u.notifyLeadMinutes);
      leadsByRoute.set(u.linkedRouteId, set);
    }

    for (const route of routes) {
      if (!route.active) continue;

      const live = await ctx.db
        .query("liveState")
        .withIndex("by_route", (q) => q.eq("routeId", route._id))
        .unique();

      const recent = await ctx.db
        .query("alerts")
        .withIndex("by_route_createdAt", (q) => q.eq("routeId", route._id))
        .order("desc")
        .take(10);

      const publishedRecently = (kind: Doc<"alerts">["kind"]) =>
        recent.some((a) => a.kind === kind && now - a.createdAt < ALERT_COOLDOWN_MS);

      const quality = signalQuality(live ?? null, now);

      if (quality === "offline") {
        if (!publishedRecently("signal")) {
          await ctx.db.insert("alerts", {
            routeId: route._id,
            routeNumber: route.number,
            kind: "signal",
            message: `${route.number} stopped reporting its location`,
            createdAt: now,
          });
          published++;
        }
        continue;
      }

      if (!live) continue;

      // Arrival heads-up, honouring each rider's lead-time preference.
      if (live.etaSeconds !== undefined && !publishedRecently("arriving")) {
        const leads = leadsByRoute.get(route._id) ?? new Set<number>();
        for (const lead of leads) {
          const window = lead * 60;
          if (live.etaSeconds <= window && live.etaSeconds > window - 60) {
            await ctx.db.insert("alerts", {
              routeId: route._id,
              routeNumber: route.number,
              kind: "arriving",
              message: `Your bus is ${minutes(live.etaSeconds)} minutes away`,
              createdAt: now,
            });
            published++;
            break;
          }
        }
      }

      if (
        live.delaySeconds !== undefined &&
        live.delaySeconds > LATE_THRESHOLD_S &&
        !publishedRecently("delay")
      ) {
        const stops = await ctx.db
          .query("stops")
          .withIndex("by_route_seq", (q) => q.eq("routeId", route._id))
          .collect();
        const nextStop = stops.find((s) => s.seq === live.nextStopSeq);
        await ctx.db.insert("alerts", {
          routeId: route._id,
          routeNumber: route.number,
          kind: "delay",
          message: `${route.number} delayed ${minutes(live.delaySeconds)} min${
            nextStop ? ` near ${nextStop.name}` : ""
          }`,
          createdAt: now,
        });
        published++;
      }
    }

    return { published };
  },
});

/**
 * Deletes position rows past the retention window.
 *
 * Bounded per run so a long backlog is worked off across several ticks
 * instead of blowing the mutation's time budget.
 */
export const prunePositions = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - POSITION_RETENTION_MS;
    const routes = await ctx.db.query("routes").collect();
    let deleted = 0;

    for (const route of routes) {
      if (deleted >= PRUNE_BATCH) break;
      const old = await ctx.db
        .query("positions")
        .withIndex("by_route_recordedAt", (q) =>
          q.eq("routeId", route._id).lt("recordedAt", cutoff),
        )
        .take(PRUNE_BATCH - deleted);
      for (const row of old) {
        await ctx.db.delete(row._id);
        deleted++;
      }
    }

    return { deleted };
  },
});

/** Clears expired sessions. Safe to run manually. */
export const pruneSessions = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const sessions = await ctx.db.query("sessions").take(500);
    let deleted = 0;
    for (const s of sessions) {
      if (s.expiresAt < now) {
        await ctx.db.delete(s._id);
        deleted++;
      }
    }
    return { deleted };
  },
});
