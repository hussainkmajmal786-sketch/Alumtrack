/**
 * D1 helpers and row types.
 *
 * Convex handed back documents with `_id`/`_creationTime` and real JS types;
 * SQLite hands back flat rows where booleans are 0/1 and absent values are
 * null. Rather than let that difference leak into every handler, each table
 * gets a row type plus a `toX()` mapper that restores the shape the rest of
 * the code (and the Flutter client) already expects.
 *
 * Ids keep Convex's format rather than switching to autoincrement, so ids
 * already baked into flashed devices, stored sessions and client state stay
 * valid across the migration.
 */

export interface Env {
  DB: D1Database;
  ADMIN_KEY?: string;
  GOOGLE_CLIENT_IDS?: string;
  ALLOWED_ORIGIN?: string;
  SCHEDULE_TZ_OFFSET_MINUTES?: string;
}

/**
 * Generates an id in the same 32-character lowercase alphanumeric shape
 * Convex used, so old and new ids are indistinguishable to clients.
 */
export function newId(): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let out = "";
  for (const b of bytes) out += alphabet[b % alphabet.length];
  return out;
}

export function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// --- Row types (as SQLite returns them) ------------------------------------

export interface RouteRow {
  id: string;
  number: string;
  name: string;
  active: number;
  scheduledArrival: string | null;
  roadPolyline: string | null;
  roadPolylineFetchedAt: number | null;
  createdAt: number;
}

export interface StopRow {
  id: string;
  routeId: string;
  seq: number;
  name: string;
  lat: number;
  lng: number;
  scheduledAt: string | null;
  createdAt: number;
}

export interface DeviceRow {
  id: string;
  deviceId: string;
  routeId: string;
  label: string | null;
  tokenHash: string;
  revoked: number;
  lastSeen: number | null;
  firmware: string | null;
  rssi: number | null;
  createdAt: number;
}

export interface LiveStateRow {
  id: string;
  routeId: string;
  lat: number;
  lng: number;
  speedKph: number | null;
  headingDeg: number | null;
  progress: number;
  nextStopSeq: number;
  etaSeconds: number | null;
  delaySeconds: number | null;
  updatedAt: number;
  source: "device" | "rider";
  accuracyM: number | null;
}

export interface UserRow {
  id: string;
  subject: string;
  email: string | null;
  name: string | null;
  pictureUrl: string | null;
  isGuest: number;
  passwordHash: string | null;
  linkedRouteId: string | null;
  linkedStopId: string | null;
  notifyLeadMinutes: number;
  createdAt: number;
  lastSeenAt: number;
}

export interface AdminRow {
  id: string;
  email: string;
  passwordHash: string;
  name: string;
  role: "admin" | "superadmin";
  active: number;
  createdAt: number;
  lastLoginAt: number | null;
}

export interface AlertRow {
  id: string;
  routeId: string | null;
  routeNumber: string | null;
  kind: "arriving" | "delay" | "signal" | "service" | "stop";
  message: string;
  createdAt: number;
  stopSeq: number | null;
}

export interface SessionRow {
  id: string;
  tokenHash: string;
  subject: string;
  createdAt: number;
  expiresAt: number;
}

export interface RiderShareRow {
  id: string;
  routeId: string;
  riderId: string;
  startedAt: number;
  lastSeen: number;
  active: number;
}

// --- Mappers ----------------------------------------------------------------

export type LatLng = { lat: number; lng: number };

/**
 * Parses the stored road polyline, tolerating absence or corruption.
 *
 * A bad polyline must never fail a request: every consumer already falls
 * back to the straight stop-to-stop line, which is exactly the behaviour
 * for a route whose geometry has not been fetched yet.
 */
export function parsePolyline(raw: string | null): LatLng[] | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length < 2) return null;
    return parsed as LatLng[];
  } catch {
    return null;
  }
}

export const bool = (v: number | null | undefined): boolean => v === 1;
export const toInt = (v: boolean): number => (v ? 1 : 0);

// --- Query helpers ----------------------------------------------------------

/** First row, or null — the equivalent of Convex's `.unique()` / `.first()`. */
export async function one<T>(stmt: D1PreparedStatement): Promise<T | null> {
  return (await stmt.first<T>()) ?? null;
}

/** All rows as a plain array. */
export async function all<T>(stmt: D1PreparedStatement): Promise<T[]> {
  const { results } = await stmt.all<T>();
  return results ?? [];
}
