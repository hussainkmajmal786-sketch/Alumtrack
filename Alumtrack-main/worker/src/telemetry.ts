/**
 * Telemetry ingest and live-state computation, ported from convex/telemetry.ts.
 *
 * The geo maths is unchanged — `lib/geo.ts` is a verbatim copy — so a fix
 * accepted by Convex is accepted here, and the progress/ETA it produces is
 * identical. What changed is only the storage calls underneath.
 */

import {
  distanceToStopM,
  etaSeconds,
  matchToRoute,
  parseClock,
  stopMarkersM,
} from "./lib/geo";
import {
  all,
  newId,
  one,
  parsePolyline,
  type Env,
  type LiveStateRow,
  type RouteRow,
  type StopRow,
} from "./lib/db";

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

function tzOffsetMinutes(env: Env): number {
  return Number(env.SCHEDULE_TZ_OFFSET_MINUTES ?? 330);
}

function secondsSinceLocalMidnight(epochMs: number, offsetMinutes: number): number {
  const shifted = epochMs + offsetMinutes * 60_000;
  return Math.floor((shifted % 86_400_000) / 1000);
}

export interface IngestArgs {
  routeId: string;
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
}

export type IngestResult =
  | { accepted: false; reason: string; offRouteM?: number }
  | { accepted: true; applied: false; reason: string }
  | { accepted: true; applied: true; progress: number; etaSeconds: number };

/**
 * Records a fix and refreshes the route's consolidated live state.
 *
 * Every external entry point (device ingest, rider sharing) authenticates
 * its caller first and then delegates here.
 */
export async function ingest(env: Env, args: IngestArgs): Promise<IngestResult> {
  const now = Date.now();

  // The raw fix is stored unconditionally, even when it is later rejected as
  // off-route. That is deliberate: the time series is the evidence trail for
  // diagnosing a route whose geometry no longer matches where the bus drives
  // — exactly the situation that off-route rejection otherwise hides.
  await env.DB.prepare(
    `INSERT INTO positions
       (id, routeId, lat, lng, speedKph, headingDeg, accuracyM, satellites,
        recordedAt, source, deviceId, riderId, createdAt)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      newId(),
      args.routeId,
      args.lat,
      args.lng,
      args.speedKph ?? null,
      args.headingDeg ?? null,
      args.accuracyM ?? null,
      args.satellites ?? null,
      args.recordedAt,
      args.source,
      args.deviceId ?? null,
      args.riderId ?? null,
      now,
    )
    .run();

  const stops = await all<StopRow>(
    env.DB.prepare(
      "SELECT * FROM stops WHERE routeId = ? ORDER BY seq ASC",
    ).bind(args.routeId),
  );
  if (stops.length < 2) return { accepted: false, reason: "route-has-no-geometry" };

  // Prefer the real road path when it has been fetched; a route with no
  // cached geometry still works, just as a straight line between stops.
  const route = await one<RouteRow>(
    env.DB.prepare("SELECT * FROM routes WHERE id = ?").bind(args.routeId),
  );
  const stopPoints = stops.map((s) => ({ lat: s.lat, lng: s.lng }));
  const road = parsePolyline(route?.roadPolyline ?? null);
  const polyline = road && road.length >= 2 ? road : stopPoints;
  const markers = stopMarkersM(polyline, stopPoints);

  const match = matchToRoute({ lat: args.lat, lng: args.lng }, polyline, markers);
  if (!match) return { accepted: false, reason: "route-has-no-geometry" };

  if (match.offRouteM > MAX_OFF_ROUTE_M) {
    return { accepted: false, reason: "off-route", offRouteM: match.offRouteM };
  }

  const existing = await one<LiveStateRow>(
    env.DB.prepare("SELECT * FROM liveState WHERE routeId = ?").bind(args.routeId),
  );

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
  if (!nextStop) return { accepted: false, reason: "route-has-no-geometry" };

  const remainingToNextM = distanceToStopM(match, markers, match.nextStopIndex);
  const eta = etaSeconds(remainingToNextM, args.speedKph);

  // Delay is measured against the next stop's scheduled time: where we
  // predict arriving versus when the timetable says we should.
  let delaySeconds: number | null = null;
  const scheduled = parseClock(nextStop.scheduledAt ?? undefined);
  if (scheduled !== null) {
    const predictedArrival = secondsSinceLocalMidnight(now, tzOffsetMinutes(env)) + eta;
    let diff = predictedArrival - scheduled;
    // Fold day wrap-around (e.g. predicting 00:05 against a 23:50 schedule).
    if (diff > 43_200) diff -= 86_400;
    if (diff < -43_200) diff += 86_400;
    delaySeconds = diff;
  }

  // Upsert on routeId, which is UNIQUE — one live state per route. Doing it
  // in a single statement rather than select-then-branch removes a race
  // between two fixes arriving for the same route at once.
  await env.DB.prepare(
    `INSERT INTO liveState
       (id, routeId, lat, lng, speedKph, headingDeg, progress, nextStopSeq,
        etaSeconds, delaySeconds, updatedAt, source, accuracyM)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (routeId) DO UPDATE SET
       lat = excluded.lat,
       lng = excluded.lng,
       speedKph = excluded.speedKph,
       headingDeg = excluded.headingDeg,
       progress = excluded.progress,
       nextStopSeq = excluded.nextStopSeq,
       etaSeconds = excluded.etaSeconds,
       delaySeconds = excluded.delaySeconds,
       updatedAt = excluded.updatedAt,
       source = excluded.source,
       accuracyM = excluded.accuracyM`,
  )
    .bind(
      existing?.id ?? newId(),
      args.routeId,
      args.lat,
      args.lng,
      args.speedKph ?? null,
      args.headingDeg ?? null,
      match.progress,
      nextStop.seq,
      eta,
      delaySeconds,
      now,
      args.source,
      args.accuracyM ?? null,
    )
    .run();

  return { accepted: true, applied: true, progress: match.progress, etaSeconds: eta };
}

/** Signal quality derived from how fresh and how precise the live fix is. */
export type SignalQuality = "good" | "weak" | "offline";

export function signalQuality(live: LiveStateRow | null, now: number): SignalQuality {
  if (!live) return "offline";
  const age = now - live.updatedAt;
  if (age > STALE_AFTER_MS) return "offline";
  // A rider-sourced fix means the onboard unit already went quiet, and a
  // low-accuracy fix is not worth presenting as precise.
  if (live.source === "rider") return "weak";
  if (live.accuracyM !== null && live.accuracyM > 75) return "weak";
  if (age > STALE_AFTER_MS / 2) return "weak";
  return "good";
}
