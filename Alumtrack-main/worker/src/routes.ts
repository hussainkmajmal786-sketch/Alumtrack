/**
 * Route listing and detail, ported from convex/routes.ts.
 *
 * The JSON these produce is what the Flutter client already parses, field
 * for field — including the per-stop distanceM/etaSeconds and the
 * roadPolyline — so the app needs no model changes, only a new base URL.
 */

import { distanceToStopM, etaSeconds, stopMarkersM } from "./lib/geo";
import {
  all,
  one,
  parsePolyline,
  type Env,
  type LiveStateRow,
  type RouteRow,
  type StopRow,
} from "./lib/db";
import { signalQuality, STALE_AFTER_MS } from "./telemetry";

export type RouteStatus = "onTime" | "late" | "weak" | "offline";

/** Late by more than this is worth calling out to riders. */
const LATE_THRESHOLD_S = 120;

function statusFor(live: LiveStateRow | null, now: number): RouteStatus {
  const quality = signalQuality(live, now);
  if (quality === "offline") return "offline";
  if (quality === "weak") return "weak";
  if (live?.delaySeconds !== null && live !== null && live.delaySeconds > LATE_THRESHOLD_S) {
    return "late";
  }
  return "onTime";
}

async function liveFor(env: Env, routeId: string): Promise<LiveStateRow | null> {
  return one<LiveStateRow>(
    env.DB.prepare("SELECT * FROM liveState WHERE routeId = ?").bind(routeId),
  );
}

/**
 * Riders counted as actively sharing: flagged active *and* seen recently.
 * The staleness filter is applied at read time, so a phone that stopped
 * reporting without a clean sign-off drops out of the count immediately
 * rather than waiting for the sweep cron.
 */
async function activeRiderCount(env: Env, routeId: string): Promise<number> {
  const cutoff = Date.now() - STALE_AFTER_MS;
  const row = await one<{ n: number }>(
    env.DB.prepare(
      "SELECT COUNT(*) AS n FROM riderShares WHERE routeId = ? AND active = 1 AND lastSeen >= ?",
    ).bind(routeId, cutoff),
  );
  return row?.n ?? 0;
}

/** Every active route with its current status — backs the Buses list. */
export async function list(env: Env) {
  const now = Date.now();
  const routes = await all<RouteRow>(
    env.DB.prepare("SELECT * FROM routes WHERE active = 1"),
  );

  const rows = await Promise.all(
    routes.map(async (route) => {
      const live = await liveFor(env, route.id);
      const status = statusFor(live, now);

      // Lightweight geometry only — enough for the small preview thumbnail
      // on each list row, not the full detail payload.
      const stops = await all<StopRow>(
        env.DB.prepare(
          "SELECT lat, lng FROM stops WHERE routeId = ? ORDER BY seq ASC",
        ).bind(route.id),
      );

      return {
        id: route.id,
        number: route.number,
        name: route.name,
        status,
        etaSeconds: status === "offline" ? null : (live?.etaSeconds ?? null),
        delaySeconds: live?.delaySeconds ?? null,
        updatedAt: live?.updatedAt ?? null,
        previewPoints: stops.map((s) => ({ lat: s.lat, lng: s.lng })),
      };
    }),
  );

  rows.sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true }));
  return { routes: rows, serverNow: now };
}

/** Full detail for one route — backs the Live status screen. */
export async function detail(env: Env, routeId: string) {
  const route = await one<RouteRow>(
    env.DB.prepare("SELECT * FROM routes WHERE id = ?").bind(routeId),
  );
  if (!route) return null;

  const stops = await all<StopRow>(
    env.DB.prepare("SELECT * FROM stops WHERE routeId = ? ORDER BY seq ASC").bind(routeId),
  );

  const live = await liveFor(env, routeId);
  const now = Date.now();
  const status = statusFor(live, now);
  const riders = await activeRiderCount(env, routeId);

  const nextSeq = live?.nextStopSeq ?? 0;

  // Per-stop distance/ETA, measured along the real road path when one has
  // been fetched (falling back to the straight stop-to-stop line otherwise)
  // — the same geometry ingest matches fixes against, so these numbers
  // never disagree with what moved the bus pin.
  const stopPoints = stops.map((s) => ({ lat: s.lat, lng: s.lng }));
  const road = parsePolyline(route.roadPolyline);
  const polyline = road && road.length >= 2 ? road : stopPoints;
  const markers = stopMarkersM(polyline, stopPoints);
  const totalM = markers.length > 0 ? markers[markers.length - 1]! : 0;
  const travelledM = live ? live.progress * totalM : 0;

  return {
    id: route.id,
    number: route.number,
    name: route.name,
    scheduledArrival: route.scheduledArrival ?? null,
    status,
    riders,
    signal: signalQuality(live, now),
    roadPolyline: road ?? null,
    live: live
      ? {
          lat: live.lat,
          lng: live.lng,
          progress: live.progress,
          speedKph: live.speedKph ?? null,
          headingDeg: live.headingDeg ?? null,
          etaSeconds: live.etaSeconds ?? null,
          delaySeconds: live.delaySeconds ?? null,
          accuracyM: live.accuracyM ?? null,
          updatedAt: live.updatedAt,
          source: live.source,
          stale: now - live.updatedAt > STALE_AFTER_MS,
        }
      : null,
    stops: stops.map((s, i) => {
      const distanceM = live ? distanceToStopM({ travelledM }, markers, i) : null;
      return {
        seq: s.seq,
        name: s.name,
        lat: s.lat,
        lng: s.lng,
        scheduledAt: s.scheduledAt ?? null,
        state: s.seq < nextSeq ? "past" : s.seq === nextSeq ? "next" : "ahead",
        distanceM,
        etaSeconds:
          distanceM !== null && s.seq >= nextSeq
            ? etaSeconds(distanceM, live?.speedKph ?? undefined)
            : null,
      };
    }),
    serverNow: now,
  };
}

/**
 * Fetches the real road-following path through a route's stops from OSRM's
 * public demo server and caches it on the route.
 *
 * Best-effort by design: any failure leaves the previous geometry in place
 * and the map falls back to straight stop-to-stop lines, so a flaky routing
 * service degrades accuracy rather than availability.
 */
export async function fetchRoadGeometry(env: Env, routeId: string) {
  const stops = await all<StopRow>(
    env.DB.prepare(
      "SELECT lat, lng FROM stops WHERE routeId = ? ORDER BY seq ASC",
    ).bind(routeId),
  );
  if (stops.length < 2) return { ok: false, reason: "not-enough-stops" };

  const coords = stops.map((s) => `${s.lng},${s.lat}`).join(";");
  const url = `https://router.project-osrm.org/route/v1/driving/${coords}?overview=full&geometries=geojson`;

  try {
    const res = await fetch(url);
    if (!res.ok) return { ok: false, reason: `osrm-http-${res.status}` };
    const body = (await res.json()) as any;
    const coordinates = body?.routes?.[0]?.geometry?.coordinates;
    if (!Array.isArray(coordinates) || coordinates.length < 2) {
      return { ok: false, reason: "osrm-empty-geometry" };
    }

    // GeoJSON is [lng, lat]; the rest of this codebase is {lat, lng}.
    const polyline = coordinates.map((c: [number, number]) => ({ lat: c[1], lng: c[0] }));

    await env.DB.prepare(
      "UPDATE routes SET roadPolyline = ?, roadPolylineFetchedAt = ? WHERE id = ?",
    )
      .bind(JSON.stringify(polyline), Date.now(), routeId)
      .run();

    return { ok: true, points: polyline.length };
  } catch (e: any) {
    return { ok: false, reason: e?.message ?? "fetch-failed" };
  }
}

/**
 * Replaces every stop on a route in one shot, ordered by `seq`.
 *
 * Also clears the route's live state. That is not housekeeping: `progress`
 * is a fraction of the *old* polyline's length and `nextStopSeq` an index
 * into the *old* stop list, so carrying them onto different geometry makes
 * every derived distance and ETA confidently wrong until the next fix
 * arrives. Dropping it shows "no live position yet" for a few seconds
 * instead, which is honest.
 */
export async function setStops(
  env: Env,
  routeId: string,
  stops: { seq: number; name: string; lat: number; lng: number; scheduledAt?: string }[],
) {
  const route = await one<RouteRow>(
    env.DB.prepare("SELECT id FROM routes WHERE id = ?").bind(routeId),
  );
  if (!route) throw new Error("Unknown route");

  const now = Date.now();
  const statements: D1PreparedStatement[] = [
    env.DB.prepare("DELETE FROM stops WHERE routeId = ?").bind(routeId),
    env.DB.prepare("DELETE FROM liveState WHERE routeId = ?").bind(routeId),
  ];

  for (const s of stops) {
    statements.push(
      env.DB.prepare(
        `INSERT INTO stops (id, routeId, seq, name, lat, lng, scheduledAt, createdAt)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        crypto.randomUUID().replace(/-/g, "").slice(0, 32),
        routeId,
        s.seq,
        s.name,
        s.lat,
        s.lng,
        s.scheduledAt ?? null,
        now,
      ),
    );
  }

  // One batch so a partial write cannot leave a route with half its stops.
  await env.DB.batch(statements);
  return { ok: true };
}
