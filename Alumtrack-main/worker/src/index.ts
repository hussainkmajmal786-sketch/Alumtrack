/**
 * Alumtrack backend on Cloudflare Workers + D1.
 *
 * A port of the Convex deployment, route for route. Response shapes are
 * preserved exactly so the Flutter client and the ESP32 firmware need no
 * changes beyond pointing at a new base URL.
 */

import { Hono } from "hono";
import { sha256Hex, timingSafeEqualHex, bearerToken } from "./lib/auth";
import {
  all,
  newId,
  newToken,
  one,
  type AdminRow,
  type DeviceRow,
  type Env,
  type RiderShareRow,
  type UserRow,
} from "./lib/db";
import {
  corsHeaders,
  fail,
  json,
  readJson,
  requireAdmin,
  requireSubject,
  type AppContext,
} from "./lib/http";
import { ingest } from "./telemetry";
import { detail as routeDetail, fetchRoadGeometry, list as routeList, setStops } from "./routes";
import { runScheduled } from "./scheduled";

// The Variables shape is declared here, not just in AppContext, so handlers
// get the right context type directly instead of each one casting.
const app = new Hono<{
  Bindings: Env;
  Variables: { subject?: string; admin?: import("./lib/http").AdminSummary };
}>();

// One preflight handler for every path — the browser only cares that the
// CORS headers come back, not which route it asked about.
app.options("*", (c) => new Response(null, { status: 204, headers: corsHeaders(c.env) }));

app.get("/", (c) => json(c, { service: "alumtrack", ok: true }));

// ---------------------------------------------------------------------------
// Device ingest (ESP32)
// ---------------------------------------------------------------------------

/**
 * POST /api/ingest
 * Authorization: Bearer <device token>
 *
 * Accepts a single fix or `{ batch: [...] }` so a tracker that lost Wi-Fi
 * can flush its buffer in one request on reconnect.
 */
app.post("/api/ingest", async (c) => {
  const token = bearerToken(c.req.header("Authorization") ?? null);
  if (!token) return fail(c, "Missing bearer token", 401);

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);

  const deviceId = String(body.deviceId ?? "");
  if (!deviceId) return fail(c, "deviceId is required", 400);

  const device = await one<DeviceRow>(
    c.env.DB.prepare("SELECT * FROM devices WHERE deviceId = ?").bind(deviceId),
  );
  if (!device || device.revoked === 1) {
    return fail(c, "Invalid device credentials", 401);
  }

  const presented = await sha256Hex(token);
  if (!timingSafeEqualHex(presented, device.tokenHash)) {
    return fail(c, "Invalid device credentials", 401);
  }

  const fixes: any[] = Array.isArray(body.batch) ? body.batch : [body];
  if (fixes.length > 60) return fail(c, "Batch too large (max 60)", 413);

  const now = Date.now();
  const results: any[] = [];

  for (const fix of fixes) {
    const lat = Number(fix.lat);
    const lng = Number(fix.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      results.push({ accepted: false, reason: "invalid-coordinates" });
      continue;
    }
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      results.push({ accepted: false, reason: "coordinates-out-of-range" });
      continue;
    }

    // Trackers without a battery-backed RTC boot at the epoch, so an
    // implausible timestamp is replaced with arrival time rather than
    // poisoning the time series.
    const claimed = Number(fix.recordedAt);
    const recordedAt =
      Number.isFinite(claimed) && claimed > 1_600_000_000_000 && claimed < now + 60_000
        ? claimed
        : now;

    // u-blox reports HDOP, not metres. The ~5 m/HDOP rule of thumb is enough
    // to tell a clean fix from a poor one.
    const hdop = Number(fix.hdop);
    const accuracyM = Number.isFinite(hdop) ? hdop * 5 : undefined;

    results.push(
      await ingest(c.env, {
        routeId: device.routeId,
        lat,
        lng,
        speedKph: Number.isFinite(Number(fix.speedKph)) ? Number(fix.speedKph) : undefined,
        headingDeg: Number.isFinite(Number(fix.headingDeg)) ? Number(fix.headingDeg) : undefined,
        accuracyM,
        satellites: Number.isFinite(Number(fix.satellites)) ? Number(fix.satellites) : undefined,
        recordedAt,
        source: "device",
        deviceId,
      }),
    );
  }

  await c.env.DB.prepare(
    "UPDATE devices SET lastSeen = ?, firmware = COALESCE(?, firmware), rssi = COALESCE(?, rssi) WHERE deviceId = ?",
  )
    .bind(
      now,
      body.firmware ? String(body.firmware) : null,
      Number.isFinite(Number(body.rssi)) ? Number(body.rssi) : null,
      deviceId,
    )
    .run();

  // The device syncs its clock from this so buffered fixes get sane stamps.
  return json(c, { ok: true, serverTime: now, results });
});

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

async function profileFor(env: Env, subject: string) {
  return one<UserRow>(env.DB.prepare("SELECT * FROM users WHERE subject = ?").bind(subject));
}

/**
 * GET /api/routes
 *
 * The full route list sits behind sign-in; once a rider is linked to a bus
 * (by choice as a guest, or by an admin as a student) they only ever see
 * that one.
 */
app.get("/api/routes", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  const profile = await profileFor(c.env, subject);
  if (!profile) return fail(c, "Unknown user", 404);

  const listed = await routeList(c.env);
  const linkedId = profile.linkedRouteId;

  if (linkedId == null) {
    return json(c, { ...listed, restricted: false });
  }

  return json(c, {
    ...listed,
    routes: listed.routes.filter((r) => r.id === linkedId),
    restricted: true,
  });
});

/** GET /api/route?id=<routeId> */
app.get("/api/route", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  const id = c.req.query("id");
  if (!id) return fail(c, "id is required", 400);

  const profile = await profileFor(c.env, subject);
  const linkedId = profile?.linkedRouteId ?? null;
  if (linkedId != null && linkedId !== id) {
    return fail(c, "You can only view your assigned bus.", 403);
  }

  const detail = await routeDetail(c.env, id);
  if (!detail) return fail(c, "Unknown route", 404);

  const share = await one<RiderShareRow>(
    c.env.DB.prepare("SELECT * FROM riderShares WHERE riderId = ?").bind(subject),
  );
  const sharing =
    !!share && share.active === 1 && share.routeId === id;

  return json(c, { ...detail, sharing, riders: detail.riders });
});

// ---------------------------------------------------------------------------
// Admin: devices
// ---------------------------------------------------------------------------

/**
 * POST /api/admin/devices  { deviceId, routeId, label? }
 *
 * Accepts either the static ADMIN_KEY (used by firmware provisioning
 * scripts) or a logged-in admin session, so the dashboard never needs the
 * raw key handed to every admin. Returns the plaintext token exactly once.
 */
app.post("/api/admin/devices", async (c) => {
  const presented = bearerToken(c.req.header("Authorization") ?? null);
  const viaAdminKey = !!c.env.ADMIN_KEY && presented === c.env.ADMIN_KEY;
  if (!viaAdminKey && !(await requireAdmin(c))) {
    return fail(c, "Unauthorized", 401);
  }

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);
  if (!body.deviceId || !body.routeId) {
    return fail(c, "deviceId and routeId are required", 400);
  }

  const deviceToken = newToken();
  const tokenHash = await sha256Hex(deviceToken);
  const now = Date.now();

  const existing = await one<DeviceRow>(
    c.env.DB.prepare("SELECT * FROM devices WHERE deviceId = ?").bind(String(body.deviceId)),
  );

  if (existing) {
    await c.env.DB.prepare(
      "UPDATE devices SET routeId = ?, tokenHash = ?, label = COALESCE(?, label), revoked = 0 WHERE deviceId = ?",
    )
      .bind(String(body.routeId), tokenHash, body.label ? String(body.label) : null, String(body.deviceId))
      .run();
    return json(c, { deviceId: String(body.deviceId), rotated: true, token: deviceToken }, 201);
  }

  await c.env.DB.prepare(
    `INSERT INTO devices (id, deviceId, routeId, label, tokenHash, revoked, createdAt)
     VALUES (?, ?, ?, ?, ?, 0, ?)`,
  )
    .bind(newId(), String(body.deviceId), String(body.routeId), body.label ? String(body.label) : null, tokenHash, now)
    .run();

  return json(c, { deviceId: String(body.deviceId), rotated: false, token: deviceToken }, 201);
});

/** GET /api/admin/devices */
app.get("/api/admin/devices", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);

  const devices = await all<DeviceRow & { routeNumber: string | null }>(
    c.env.DB.prepare(
      `SELECT d.*, r.number AS routeNumber
         FROM devices d
         LEFT JOIN routes r ON r.id = d.routeId`,
    ),
  );

  return json(c, {
    devices: devices.map((d) => ({
      id: d.id,
      deviceId: d.deviceId,
      routeId: d.routeId,
      routeNumber: d.routeNumber,
      label: d.label,
      revoked: d.revoked === 1,
      lastSeen: d.lastSeen,
      firmware: d.firmware,
      rssi: d.rssi,
    })),
  });
});

/** POST /api/admin/routes/stops  { routeId, stops: [...] } */
app.post("/api/admin/routes/stops", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);
  if (!body.routeId || !Array.isArray(body.stops)) {
    return fail(c, "routeId and stops are required", 400);
  }

  try {
    await setStops(
      c.env,
      String(body.routeId),
      body.stops.map((s: any) => ({
        seq: Number(s.seq),
        name: String(s.name),
        lat: Number(s.lat),
        lng: Number(s.lng),
        scheduledAt: s.scheduledAt ? String(s.scheduledAt) : undefined,
      })),
    );

    // The stops just changed, so any cached road path is stale. Refetched
    // after the response via waitUntil so an admin saving stops never waits
    // on a third-party routing call.
    c.executionCtx.waitUntil(fetchRoadGeometry(c.env, String(body.routeId)));

    return json(c, { ok: true });
  } catch (e: any) {
    return fail(c, e?.message ?? "Could not update stops", 409);
  }
});

/** POST /api/admin/routes/geometry  { routeId } — manual refetch. */
app.post("/api/admin/routes/geometry", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);
  const body = await readJson(c);
  if (!body?.routeId) return fail(c, "routeId is required", 400);
  return json(c, await fetchRoadGeometry(c.env, String(body.routeId)));
});

// ---------------------------------------------------------------------------
// Admin auth
// ---------------------------------------------------------------------------

/** GET /api/admin/me */
app.get("/api/admin/me", async (c) => {
  const admin = await requireAdmin(c);
  if (!admin) return fail(c, "Unauthorized", 401);
  return json(c, admin);
});

app.notFound((c) => fail(c, "Not found", 404));

export default {
  fetch: app.fetch,

  /**
   * Cron entry point. Workers hands every trigger to one handler, so the
   * cron expression selects which job runs — see scheduled.ts.
   */
  async scheduled(event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(runScheduled(event.cron, env));
  },
};
