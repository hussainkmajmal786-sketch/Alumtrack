/**
 * Route geometry helpers.
 *
 * The route is modelled as a polyline through the ordered stop coordinates.
 * Everything here is pure so it can run inside a Convex mutation without I/O.
 */

export type LatLng = { lat: number; lng: number };

const EARTH_RADIUS_M = 6_371_000;

const toRad = (deg: number) => (deg * Math.PI) / 180;

/** Great-circle distance in metres. */
export function haversineM(a: LatLng, b: LatLng): number {
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * Project `p` onto segment `a`->`b` using a local equirectangular
 * approximation. Over the ~15km segments this route uses, the error is well
 * under a metre — far below GPS noise.
 */
function projectOntoSegment(
  p: LatLng,
  a: LatLng,
  b: LatLng,
): { t: number; point: LatLng } {
  const latRef = toRad((a.lat + b.lat) / 2);
  const x = (q: LatLng) => toRad(q.lng) * Math.cos(latRef);
  const y = (q: LatLng) => toRad(q.lat);

  const ax = x(a);
  const ay = y(a);
  const bx = x(b);
  const by = y(b);
  const px = x(p);
  const py = y(p);

  const dx = bx - ax;
  const dy = by - ay;
  const lenSq = dx * dx + dy * dy;
  if (lenSq === 0) return { t: 0, point: a };

  let t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
  t = Math.max(0, Math.min(1, t));

  return {
    t,
    point: {
      lat: a.lat + (b.lat - a.lat) * t,
      lng: a.lng + (b.lng - a.lng) * t,
    },
  };
}

export type RouteMatch = {
  /** 0..1 along the whole polyline. */
  progress: number;
  /** Index of the stop the vehicle is heading toward (1..n-1, clamped). */
  nextStopIndex: number;
  /** Metres from the reported point to the polyline. */
  offRouteM: number;
  /** Metres remaining to the final stop, measured along the polyline. */
  remainingM: number;
};

/**
 * Snap a GPS fix to the route polyline.
 *
 * Returns null when `stops` has fewer than two points.
 */
export function matchToRoute(p: LatLng, stops: LatLng[]): RouteMatch | null {
  if (stops.length < 2) return null;

  const segmentLengths: number[] = [];
  let totalM = 0;
  for (let i = 0; i < stops.length - 1; i++) {
    const len = haversineM(stops[i], stops[i + 1]);
    segmentLengths.push(len);
    totalM += len;
  }
  if (totalM === 0) return null;

  let best = {
    segment: 0,
    t: 0,
    distanceM: Number.POSITIVE_INFINITY,
  };

  for (let i = 0; i < stops.length - 1; i++) {
    const { t, point } = projectOntoSegment(p, stops[i], stops[i + 1]);
    const d = haversineM(p, point);
    if (d < best.distanceM) best = { segment: i, t, distanceM: d };
  }

  let travelledM = 0;
  for (let i = 0; i < best.segment; i++) travelledM += segmentLengths[i];
  travelledM += segmentLengths[best.segment] * best.t;

  // A fix sitting exactly on a stop belongs to the leg *after* it, so the
  // "next stop" is the one ahead rather than the one just reached.
  const nextStopIndex = Math.min(stops.length - 1, best.segment + 1);

  return {
    progress: Math.max(0, Math.min(1, travelledM / totalM)),
    nextStopIndex,
    offRouteM: best.distanceM,
    remainingM: Math.max(0, totalM - travelledM),
  };
}

/** Metres along the polyline between two stop indices. */
export function distanceAlongM(
  stops: LatLng[],
  fromProgress: number,
  toIndex: number,
): number {
  if (stops.length < 2) return 0;
  const segmentLengths: number[] = [];
  let totalM = 0;
  for (let i = 0; i < stops.length - 1; i++) {
    const len = haversineM(stops[i], stops[i + 1]);
    segmentLengths.push(len);
    totalM += len;
  }
  let toM = 0;
  for (let i = 0; i < toIndex && i < segmentLengths.length; i++) {
    toM += segmentLengths[i];
  }
  return Math.max(0, toM - fromProgress * totalM);
}

/**
 * Seconds to cover `distanceM` at `speedKph`, falling back to a nominal
 * campus-route speed when the vehicle is stopped or speed is unavailable.
 */
export function etaSeconds(
  distanceM: number,
  speedKph: number | undefined,
): number {
  const NOMINAL_KPH = 28;
  // Below walking pace the reading is noise or a halt at a stop; using it
  // would produce absurd ETAs, so fall back to the nominal cruise speed.
  const kph = speedKph !== undefined && speedKph > 5 ? speedKph : NOMINAL_KPH;
  return Math.round((distanceM / (kph * 1000)) * 3600);
}

/** Parse "HH:mm" into seconds since local midnight, or null. */
export function parseClock(hhmm: string | undefined): number | null {
  if (!hhmm) return null;
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm.trim());
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  return h * 3600 + min * 60;
}
