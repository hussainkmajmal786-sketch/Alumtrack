import { internalMutation } from "./_generated/server";
import { Id } from "./_generated/dataModel";

/**
 * Seeds the six Kottayam ⇄ CEK Kidangoor routes.
 *
 * Idempotent: routes are keyed by number, so re-running refreshes stop
 * geometry without duplicating anything. Run with:
 *   npx convex run seed:run
 */

type SeedStop = { name: string; lat: number; lng: number; scheduledAt?: string };
type SeedRoute = {
  number: string;
  name: string;
  scheduledArrival?: string;
  stops: SeedStop[];
};

// Real coordinates along the Kottayam -> College of Engineering Kidangoor corridor.
const MAIN_CORRIDOR: SeedStop[] = [
  { name: "Kottayam KSRTC", lat: 9.5926, lng: 76.5222, scheduledAt: "09:22" },
  { name: "Malam", lat: 9.614, lng: 76.554, scheduledAt: "09:31" },
  { name: "Oravakal", lat: 9.6265, lng: 76.5695, scheduledAt: "09:38" },
  { name: "Ayarkunnam", lat: 9.639, lng: 76.585, scheduledAt: "09:46" },
  { name: "Manthadi", lat: 9.648, lng: 76.6015, scheduledAt: "09:54" },
  { name: "Kidangoor Junction", lat: 9.66, lng: 76.6175, scheduledAt: "10:00" },
  {
    name: "College of Engineering Kidangoor",
    lat: 9.6655,
    lng: 76.6285,
    scheduledAt: "10:05",
  },
];

const ROUTES: SeedRoute[] = [
  {
    number: "12",
    name: "Kottayam ⇄ CEK Kidangoor",
    scheduledArrival: "10:05",
    stops: MAIN_CORRIDOR,
  },
  {
    number: "04",
    name: "Town ⇄ Ayarkunnam",
    scheduledArrival: "09:50",
    stops: MAIN_CORRIDOR.slice(0, 4),
  },
  {
    number: "08",
    name: "CEK ⇄ Kidangoor Junction",
    scheduledArrival: "10:05",
    stops: MAIN_CORRIDOR.slice(5),
  },
  {
    number: "19",
    name: "KSRTC Stand ⇄ Manthadi",
    scheduledArrival: "09:54",
    stops: MAIN_CORRIDOR.slice(0, 5),
  },
  {
    number: "27",
    name: "Manthadi Loop",
    scheduledArrival: "10:12",
    stops: [
      MAIN_CORRIDOR[4],
      MAIN_CORRIDOR[5],
      MAIN_CORRIDOR[6],
      { name: "Manthadi", lat: 9.648, lng: 76.6015, scheduledAt: "10:12" },
    ],
  },
  {
    number: "33",
    name: "Oravakal ⇄ Malam",
    scheduledArrival: "09:40",
    stops: [MAIN_CORRIDOR[2], MAIN_CORRIDOR[1]],
  },
];

export const run = internalMutation({
  args: {},
  handler: async (ctx) => {
    let created = 0;
    let refreshed = 0;

    for (const spec of ROUTES) {
      const existing = await ctx.db
        .query("routes")
        .withIndex("by_number", (q) => q.eq("number", spec.number))
        .unique();

      let routeId: Id<"routes">;
      if (existing) {
        await ctx.db.patch(existing._id, {
          name: spec.name,
          active: true,
          scheduledArrival: spec.scheduledArrival,
        });
        routeId = existing._id;
        refreshed++;

        const oldStops = await ctx.db
          .query("stops")
          .withIndex("by_route", (q) => q.eq("routeId", routeId))
          .collect();
        for (const s of oldStops) await ctx.db.delete(s._id);
      } else {
        routeId = await ctx.db.insert("routes", {
          number: spec.number,
          name: spec.name,
          active: true,
          scheduledArrival: spec.scheduledArrival,
        });
        created++;
      }

      for (let i = 0; i < spec.stops.length; i++) {
        const s = spec.stops[i];
        await ctx.db.insert("stops", {
          routeId,
          seq: i,
          name: s.name,
          lat: s.lat,
          lng: s.lng,
          scheduledAt: s.scheduledAt,
        });
      }
    }

    return { created, refreshed, routes: ROUTES.length };
  },
});

/** Wipes live state and telemetry without touching route definitions. */
export const resetLiveData = internalMutation({
  args: {},
  handler: async (ctx) => {
    for (const table of ["liveState", "positions", "riderShares", "alerts"] as const) {
      const rows = await ctx.db.query(table).take(1000);
      for (const row of rows) await ctx.db.delete(row._id);
    }
    return { ok: true };
  },
});
