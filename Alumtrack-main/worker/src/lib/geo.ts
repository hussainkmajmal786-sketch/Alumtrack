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
  /** Total polyline length, in metres — callers need this to convert a
   *  cumulative distance-along back to a distance-remaining for one stop. */
  totalM: number;
  /** This fix's own cumulative distance along the polyline, in metres. */
  travelledM: number;
};

/** Cumulative distance to the start of each segment, plus the total length. */
function segmentPrefix(points: LatLng[]): { lengths: number[]; totalM: number } {
  const lengths: number[] = [];
  let totalM = 0;
  for (let i = 0; i < points.length - 1; i++) {
    const len = haversineM(points[i], points[i + 1]);
    lengths.push(len);
    totalM += len;
  }
  return { lengths, totalM };
}

/**
 * Snap a GPS fix to a route polyline.
 *
 * `polyline` is the geometry actually driven — either the dense road-follow
 * path from the routing engine, or (when that has not been fetched yet) the
 * straight line through the stops themselves. Either way it need not be the
 * stops array: `stopMarkersM`, computed once from whichever polyline is in
 * use, is what maps a matched position back to "which stop is next".
 *
 * Returns null when `polyline` has fewer than two points.
 */
export function matchToRoute(
  p: LatLng,
  polyline: LatLng[],
  stopMarkersM: number[],
): RouteMatch | null {
  if (polyline.length < 2) return null;

  const { lengths: segmentLengths, totalM } = segmentPrefix(polyline);
  if (totalM === 0) return null;

  let best = {
    segment: 0,
    t: 0,
    distanceM: Number.POSITIVE_INFINITY,
  };

  for (let i = 0; i < polyline.length - 1; i++) {
    const { t, point } = projectOntoSegment(p, polyline[i], polyline[i + 1]);
    const d = haversineM(p, point);
    if (d < best.distanceM) best = { segment: i, t, distanceM: d };
  }

  let travelledM = 0;
  for (let i = 0; i < best.segment; i++) travelledM += segmentLengths[i];
  travelledM += segmentLengths[best.segment] * best.t;

  // The next stop is the first stop marker strictly ahead of the matched
  // position — independent of how many polyline points lie between here and
  // there, which is what makes this work for a dense road polyline and not
  // just a stops-only one.
  let nextStopIndex = stopMarkersM.length - 1;
  for (let i = 0; i < stopMarkersM.length; i++) {
    if (stopMarkersM[i] > travelledM + 1e-6) {
      nextStopIndex = i;
      break;
    }
  }

  return {
    progress: Math.max(0, Math.min(1, travelledM / totalM)),
    nextStopIndex,
    offRouteM: best.distanceM,
    remainingM: Math.max(0, totalM - travelledM),
    totalM,
    travelledM,
  };
}

/**
 * For each stop, its cumulative distance along `polyline` in metres — found
 * by matching each stop's own coordinates onto the polyline. This is the
 * bridge between "a dense road-follow path" and "which stop is at which
 * point along it", since a road polyline's own points are not the stops.
 */
export function stopMarkersM(polyline: LatLng[], stops: LatLng[]): number[] {
  if (polyline.length < 2) {
    // No usable polyline: fall back to even spacing so callers still get a
    // monotonically increasing marker per stop rather than crashing.
    return stops.map((_, i) => i);
  }
  const { lengths: segmentLengths } = segmentPrefix(polyline);
  return stops.map((stop) => {
    let best = { segment: 0, t: 0, distanceM: Number.POSITIVE_INFINITY };
    for (let i = 0; i < polyline.length - 1; i++) {
      const { t, point } = projectOntoSegment(stop, polyline[i], polyline[i + 1]);
      const d = haversineM(stop, point);
      if (d < best.distanceM) best = { segment: i, t, distanceM: d };
    }
    let travelledM = 0;
    for (let i = 0; i < best.segment; i++) travelledM += segmentLengths[i];
    travelledM += segmentLengths[best.segment] * best.t;
    return travelledM;
  });
}

/** Metres along the polyline between a fix's progress and one stop index. */
export function distanceToStopM(
  match: Pick<RouteMatch, "travelledM">,
  stopMarkersM: number[],
  stopIndex: number,
): number {
  const target = stopMarkersM[stopIndex] ?? 0;
  return Math.max(0, target - match.travelledM);
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
