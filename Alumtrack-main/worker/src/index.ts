/**
 * Alumtrack backend on Cloudflare Workers + D1.
 *
 * A port of the Convex deployment, route for route. Response shapes are
 * preserved exactly so the Flutter client and the ESP32 firmware need no
 * changes beyond pointing at a new base URL.
 */

import { Hono } from "hono";
import { hashPassword, sha256Hex, timingSafeEqualHex, bearerToken } from "./lib/auth";
import {
  all,
  newId,
  newToken,
  one,
  type AdminRow,
  type AlertRow,
  type DeviceRow,
  type Env,
  type RiderShareRow,
  type RouteRow,
  type StopRow,
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
import { ingest, STALE_AFTER_MS } from "./telemetry";
import {
  issueSession,
  profileFor as profileForSubject,
  signOut,
  signUpWithPassword,
  updatePreferences,
  upsertAndIssueSession,
  verifyAdminCredentials,
  verifyGoogleIdToken,
  verifyStudentPassword,
} from "./users";
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
// Auth
// ---------------------------------------------------------------------------

/** POST /api/auth/google  { idToken } */
app.post("/api/auth/google", async (c) => {
  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);

  const idToken = String(body.idToken ?? "");
  if (!idToken) return fail(c, "idToken is required", 400);

  const verified = await verifyGoogleIdToken(c.env, idToken);
  if (!verified.ok) return fail(c, verified.message, verified.status);

  const claims = verified.claims;
  const subject = `google:${claims.sub}`;
  const token = newToken();

  await upsertAndIssueSession(c.env, {
    subject,
    email: claims.email,
    name: claims.name,
    pictureUrl: claims.picture,
    isGuest: false,
    tokenHash: await sha256Hex(token),
  });

  return json(c, { token, subject });
});

/**
 * POST /api/auth/guest
 *
 * Issues an anonymous session so guests get a stable identity for their
 * linked bus and rider sharing without signing in.
 */
app.post("/api/auth/guest", async (c) => {
  const token = newToken();
  const subject = `guest:${newToken().slice(0, 24)}`;
  await upsertAndIssueSession(c.env, {
    subject,
    isGuest: true,
    tokenHash: await sha256Hex(token),
  });
  return json(c, { token, subject });
});

/**
 * POST /api/auth/student-signup  { email, password, name? }
 *
 * Alternative to Google Sign-In. Deliberately simple: no email
 * verification, no college-domain restriction.
 */
app.post("/api/auth/student-signup", async (c) => {
  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);

  const email = String(body.email ?? "").trim();
  const password = String(body.password ?? "");
  const name = body.name ? String(body.name).trim() : undefined;

  if (!email || !email.includes("@")) return fail(c, "A valid email is required", 400);
  if (password.length < 6) return fail(c, "Password must be at least 6 characters", 400);

  let subject: string;
  try {
    ({ subject } = await signUpWithPassword(c.env, email, password, name));
  } catch (e: any) {
    return fail(c, e?.message ?? "Sign-up failed", 409);
  }

  const token = newToken();
  await issueSession(c.env, subject, await sha256Hex(token));
  return json(c, { token, subject });
});

/** POST /api/auth/student-login  { email, password } */
app.post("/api/auth/student-login", async (c) => {
  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);

  const email = String(body.email ?? "").trim();
  const password = String(body.password ?? "");
  if (!email || !password) return fail(c, "email and password are required", 400);

  const user = await verifyStudentPassword(c.env, email, password);
  if (!user) return fail(c, "Incorrect email or password", 401);

  const token = newToken();
  await issueSession(c.env, user.subject, await sha256Hex(token));
  return json(c, { token, subject: user.subject });
});

/** POST /api/auth/admin-login  { email, password } */
app.post("/api/auth/admin-login", async (c) => {
  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);

  const email = String(body.email ?? "");
  const password = String(body.password ?? "");
  if (!email || !password) return fail(c, "email and password are required", 400);

  const admin = await verifyAdminCredentials(c.env, email, password);
  if (!admin) return fail(c, "Incorrect email or password", 401);

  const token = newToken();
  const now = Date.now();
  // Staff sessions are shorter-lived than student ones; the subject prefix
  // is what later tells an admin session apart from a rider's.
  await c.env.DB.prepare(
    "INSERT INTO sessions (id, tokenHash, subject, createdAt, expiresAt) VALUES (?, ?, ?, ?, ?)",
  )
    .bind(newId(), await sha256Hex(token), `admin:${admin.id}`, now, now + 1000 * 60 * 60 * 24 * 14)
    .run();
  await c.env.DB.prepare("UPDATE admins SET lastLoginAt = ? WHERE id = ?").bind(now, admin.id).run();

  return json(c, { token, role: admin.role, name: admin.name, email: admin.email });
});

/** POST /api/auth/signout */
app.post("/api/auth/signout", async (c) => {
  const token = bearerToken(c.req.header("Authorization") ?? null);
  if (token) await signOut(c.env, await sha256Hex(token));
  return json(c, { ok: true });
});

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

/** GET /api/me */
app.get("/api/me", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);
  const profile = await profileForSubject(c.env, subject);
  if (!profile) return fail(c, "Unknown user", 404);
  return json(c, profile);
});

/** POST /api/me  { notifyLeadMinutes?, linkedRouteId? } */
app.post("/api/me", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);

  try {
    await updatePreferences(c.env, subject, {
      notifyLeadMinutes:
        body.notifyLeadMinutes !== undefined ? Number(body.notifyLeadMinutes) : undefined,
      linkedRouteId: body.linkedRouteId !== undefined ? body.linkedRouteId : undefined,
    });
  } catch (e: any) {
    return fail(c, e?.message ?? "Could not update preferences", 400);
  }

  return json(c, await profileForSubject(c.env, subject));
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

// ---------------------------------------------------------------------------
// Alerts
// ---------------------------------------------------------------------------

/** GET /api/alerts */
app.get("/api/alerts", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  const user = await profileFor(c.env, subject);
  const linked = user?.linkedRouteId ?? null;

  // Broadcast alerts (routeId NULL) go to everyone; route-specific ones
  // only to riders on that route. Filtered in SQL rather than in memory so
  // the 60-row page is 60 relevant rows, not 60 rows that might all be for
  // other buses.
  const items = await all<AlertRow>(
    c.env.DB.prepare(
      `SELECT * FROM alerts
        WHERE routeId IS NULL OR routeId = ?
        ORDER BY createdAt DESC
        LIMIT 60`,
    ).bind(linked),
  );

  const read = await one<{ readThrough: number }>(
    c.env.DB.prepare("SELECT readThrough FROM alertReads WHERE subject = ?").bind(subject),
  );
  const readThrough = read?.readThrough ?? 0;

  return json(c, {
    unread: items.filter((a) => a.createdAt > readThrough).length,
    items: items.map((a) => ({
      id: a.id,
      kind: a.kind,
      message: a.message,
      createdAt: a.createdAt,
      unread: a.createdAt > readThrough,
      routeNumber: a.routeNumber,
    })),
  });
});

/** POST /api/alerts/read */
app.post("/api/alerts/read", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  await c.env.DB.prepare(
    `INSERT INTO alertReads (id, subject, readThrough) VALUES (?, ?, ?)
       ON CONFLICT (subject) DO UPDATE SET readThrough = excluded.readThrough`,
  )
    .bind(newId(), subject, Date.now())
    .run();

  return json(c, { ok: true });
});

// ---------------------------------------------------------------------------
// Rider-assisted tracking
// ---------------------------------------------------------------------------

/** Active sharers on a route, counting only those seen recently. */
async function riderCount(env: Env, routeId: string): Promise<number> {
  const row = await one<{ n: number }>(
    env.DB.prepare(
      "SELECT COUNT(*) AS n FROM riderShares WHERE routeId = ? AND active = 1 AND lastSeen >= ?",
    ).bind(routeId, Date.now() - STALE_AFTER_MS),
  );
  return row?.n ?? 0;
}

/** POST /api/share  { routeId, active } */
app.post("/api/share", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);
  if (!body.routeId) return fail(c, "routeId is required", 400);

  const routeId = String(body.routeId);
  const active = !!body.active;
  const now = Date.now();

  const existing = await one<RiderShareRow>(
    c.env.DB.prepare("SELECT * FROM riderShares WHERE riderId = ?").bind(subject),
  );

  if (existing) {
    // startedAt only resets when sharing transitions off -> on, so the
    // "sharing since" clock is not restarted by a route switch mid-session.
    const startedAt = active && existing.active !== 1 ? now : existing.startedAt;
    await c.env.DB.prepare(
      "UPDATE riderShares SET routeId = ?, active = ?, lastSeen = ?, startedAt = ? WHERE riderId = ?",
    )
      .bind(routeId, active ? 1 : 0, now, startedAt, subject)
      .run();
  } else if (active) {
    await c.env.DB.prepare(
      "INSERT INTO riderShares (id, routeId, riderId, startedAt, lastSeen, active) VALUES (?, ?, ?, ?, ?, 1)",
    )
      .bind(newId(), routeId, subject, now, now)
      .run();
  }

  return json(c, { active, count: await riderCount(c.env, routeId) });
});

/** POST /api/share/fix  { routeId, lat, lng, speedKph?, headingDeg?, accuracyM? } */
app.post("/api/share/fix", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);

  const lat = Number(body.lat);
  const lng = Number(body.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return fail(c, "lat and lng are required", 400);
  }

  const routeId = String(body.routeId ?? "");
  // An active share is required, so knowing a route id is not enough to
  // move someone else's bus.
  const share = await one<RiderShareRow>(
    c.env.DB.prepare("SELECT * FROM riderShares WHERE riderId = ?").bind(subject),
  );
  if (!share || share.active !== 1 || share.routeId !== routeId) {
    return fail(c, "No active location share for this rider on this route", 409);
  }

  await c.env.DB.prepare("UPDATE riderShares SET lastSeen = ? WHERE riderId = ?")
    .bind(Date.now(), subject)
    .run();

  const result = await ingest(c.env, {
    routeId,
    lat,
    lng,
    speedKph: Number.isFinite(Number(body.speedKph)) ? Number(body.speedKph) : undefined,
    headingDeg: Number.isFinite(Number(body.headingDeg)) ? Number(body.headingDeg) : undefined,
    accuracyM: Number.isFinite(Number(body.accuracyM)) ? Number(body.accuracyM) : undefined,
    recordedAt: Date.now(),
    source: "rider",
    riderId: subject,
  });

  return json(c, result);
});

// ---------------------------------------------------------------------------
// Trip feedback
// ---------------------------------------------------------------------------

/** POST /api/feedback  { routeId, rating, comment?, tripEndedAt } */
app.post("/api/feedback", async (c) => {
  const subject = await requireSubject(c);
  if (!subject) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);
  if (!body.routeId) return fail(c, "routeId is required", 400);

  const rating = Number(body.rating);
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
    return fail(c, "rating must be an integer from 1 to 5", 400);
  }
  const tripEndedAt = Number(body.tripEndedAt);
  if (!Number.isFinite(tripEndedAt)) return fail(c, "tripEndedAt is required", 400);

  // The unique index on (subject, routeId, tripEndedAt) makes the
  // one-rating-per-trip rule the database's job; an upsert then lets a
  // rider correct their rating without a check-then-insert race.
  await c.env.DB.prepare(
    `INSERT INTO feedback (id, routeId, subject, rating, comment, tripEndedAt, createdAt)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (subject, routeId, tripEndedAt)
       DO UPDATE SET rating = excluded.rating, comment = excluded.comment`,
  )
    .bind(
      newId(),
      String(body.routeId),
      subject,
      rating,
      body.comment ? String(body.comment).slice(0, 1000) : null,
      tripEndedAt,
      Date.now(),
    )
    .run();

  return json(c, { ok: true });
});

// ---------------------------------------------------------------------------
// Admin: routes
// ---------------------------------------------------------------------------

/** GET /api/admin/routes — every route, including inactive ones. */
app.get("/api/admin/routes", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);

  const routes = await all<RouteRow>(c.env.DB.prepare("SELECT * FROM routes"));
  const out = await Promise.all(
    routes.map(async (r) => {
      const stops = await all<StopRow>(
        c.env.DB.prepare("SELECT * FROM stops WHERE routeId = ? ORDER BY seq ASC").bind(r.id),
      );
      return {
        id: r.id,
        number: r.number,
        name: r.name,
        active: r.active === 1,
        scheduledArrival: r.scheduledArrival,
        stops: stops.map((s) => ({
          id: s.id,
          seq: s.seq,
          name: s.name,
          lat: s.lat,
          lng: s.lng,
          scheduledAt: s.scheduledAt,
        })),
      };
    }),
  );

  out.sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true }));
  return json(c, { routes: out });
});

/** POST /api/admin/routes  { number, name, scheduledArrival? } */
app.post("/api/admin/routes", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body) return fail(c, "Body must be JSON", 400);
  if (!body.number || !body.name) return fail(c, "number and name are required", 400);

  const id = newId();
  await c.env.DB.prepare(
    "INSERT INTO routes (id, number, name, active, scheduledArrival, createdAt) VALUES (?, ?, ?, 1, ?, ?)",
  )
    .bind(id, String(body.number), String(body.name), body.scheduledArrival ? String(body.scheduledArrival) : null, Date.now())
    .run();

  return json(c, { id }, 201);
});

/** POST /api/admin/routes/update  { routeId, number?, name?, active?, scheduledArrival? } */
app.post("/api/admin/routes/update", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body?.routeId) return fail(c, "routeId is required", 400);

  const sets: string[] = [];
  const binds: unknown[] = [];
  if (body.number !== undefined) { sets.push("number = ?"); binds.push(String(body.number)); }
  if (body.name !== undefined) { sets.push("name = ?"); binds.push(String(body.name)); }
  if (body.active !== undefined) { sets.push("active = ?"); binds.push(body.active ? 1 : 0); }
  if (body.scheduledArrival !== undefined) {
    sets.push("scheduledArrival = ?");
    binds.push(String(body.scheduledArrival));
  }
  if (sets.length === 0) return json(c, { ok: true });

  binds.push(String(body.routeId));
  await c.env.DB.prepare(`UPDATE routes SET ${sets.join(", ")} WHERE id = ?`).bind(...binds).run();
  return json(c, { ok: true });
});

/** POST /api/admin/devices/revoke  { deviceId } */
app.post("/api/admin/devices/revoke", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);
  const body = await readJson(c);
  if (!body?.deviceId) return fail(c, "deviceId is required", 400);

  await c.env.DB.prepare("UPDATE devices SET revoked = 1 WHERE deviceId = ?")
    .bind(String(body.deviceId))
    .run();
  return json(c, { ok: true });
});

// ---------------------------------------------------------------------------
// Admin: students
// ---------------------------------------------------------------------------

/** GET /api/admin/students */
app.get("/api/admin/students", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);

  const students = await all<
    UserRow & { routeNumber: string | null; stopName: string | null }
  >(
    c.env.DB.prepare(
      `SELECT u.*, r.number AS routeNumber, s.name AS stopName
         FROM users u
         LEFT JOIN routes r ON r.id = u.linkedRouteId
         LEFT JOIN stops s ON s.id = u.linkedStopId
        WHERE u.isGuest = 0
        ORDER BY u.lastSeenAt DESC`,
    ),
  );

  return json(c, {
    students: students.map((u) => ({
      subject: u.subject,
      email: u.email,
      name: u.name,
      pictureUrl: u.pictureUrl,
      linkedRouteId: u.linkedRouteId,
      linkedRouteNumber: u.routeNumber,
      linkedStopId: u.linkedStopId,
      linkedStopName: u.stopName,
      lastSeenAt: u.lastSeenAt,
    })),
  });
});

/** POST /api/admin/students/assign-route  { subjects, routeId } */
app.post("/api/admin/students/assign-route", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);
  const body = await readJson(c);
  if (!Array.isArray(body?.subjects)) return fail(c, "subjects is required", 400);

  const routeId = body.routeId ? String(body.routeId) : null;
  // Clearing linkedStopId alongside is not incidental: a pinned stop only
  // means anything within its own route, so carrying it across a route
  // change would leave a student pinned to a stop on a bus they no longer
  // ride.
  const statements = body.subjects.map((s: unknown) =>
    c.env.DB.prepare(
      "UPDATE users SET linkedRouteId = ?, linkedStopId = NULL WHERE subject = ?",
    ).bind(routeId, String(s)),
  );
  if (statements.length > 0) await c.env.DB.batch(statements);

  return json(c, { ok: true, updated: statements.length });
});

/** POST /api/admin/students/assign-stop  { subjects, stopId } */
app.post("/api/admin/students/assign-stop", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);
  const body = await readJson(c);
  if (!Array.isArray(body?.subjects)) return fail(c, "subjects is required", 400);

  const stopId = body.stopId ? String(body.stopId) : null;
  const statements = body.subjects.map((s: unknown) =>
    c.env.DB.prepare("UPDATE users SET linkedStopId = ? WHERE subject = ?").bind(stopId, String(s)),
  );
  if (statements.length > 0) await c.env.DB.batch(statements);

  return json(c, { ok: true, updated: statements.length });
});

/** POST /api/admin/students/remove  { subject } */
app.post("/api/admin/students/remove", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);
  const body = await readJson(c);
  if (!body?.subject) return fail(c, "subject is required", 400);

  // Sessions go too, so removing an account actually signs it out rather
  // than leaving a live bearer token for a user that no longer exists.
  await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM sessions WHERE subject = ?").bind(String(body.subject)),
    c.env.DB.prepare("DELETE FROM users WHERE subject = ?").bind(String(body.subject)),
  ]);

  return json(c, { ok: true });
});

// ---------------------------------------------------------------------------
// Admin: staff accounts (superadmin only)
// ---------------------------------------------------------------------------

/** Not counting the superadmin, per the college's staffing plan. */
const MAX_ADMINS = 4;

/** GET /api/admin/admins */
app.get("/api/admin/admins", async (c) => {
  if (!(await requireAdmin(c, "superadmin"))) return fail(c, "Unauthorized", 401);

  const admins = await all<AdminRow>(
    c.env.DB.prepare("SELECT * FROM admins ORDER BY createdAt ASC"),
  );
  return json(c, {
    admins: admins.map((a) => ({
      id: a.id,
      email: a.email,
      name: a.name,
      role: a.role,
      active: a.active === 1,
      createdAt: a.createdAt,
      lastLoginAt: a.lastLoginAt,
    })),
  });
});

/** POST /api/admin/admins  { email, password, name } */
app.post("/api/admin/admins", async (c) => {
  if (!(await requireAdmin(c, "superadmin"))) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body?.email || !body?.password || !body?.name) {
    return fail(c, "email, password and name are required", 400);
  }

  const email = String(body.email).trim().toLowerCase();
  const existing = await one<AdminRow>(
    c.env.DB.prepare("SELECT id FROM admins WHERE email = ?").bind(email),
  );
  if (existing) return fail(c, "An account with that email already exists", 409);

  const seats = await one<{ n: number }>(
    c.env.DB.prepare("SELECT COUNT(*) AS n FROM admins WHERE role = 'admin' AND active = 1"),
  );
  if ((seats?.n ?? 0) >= MAX_ADMINS) {
    return fail(c, `Only ${MAX_ADMINS} admins are allowed at a time`, 409);
  }

  const id = newId();
  await c.env.DB.prepare(
    "INSERT INTO admins (id, email, passwordHash, name, role, active, createdAt) VALUES (?, ?, ?, ?, 'admin', 1, ?)",
  )
    .bind(id, email, await hashPassword(String(body.password)), String(body.name), Date.now())
    .run();

  return json(c, { id }, 201);
});

/** POST /api/admin/admins/active  { adminId, active } */
app.post("/api/admin/admins/active", async (c) => {
  if (!(await requireAdmin(c, "superadmin"))) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body?.adminId) return fail(c, "adminId is required", 400);

  const target = await one<AdminRow>(
    c.env.DB.prepare("SELECT * FROM admins WHERE id = ?").bind(String(body.adminId)),
  );
  if (!target) return fail(c, "Unknown admin", 404);
  if (target.role === "superadmin") return fail(c, "Cannot deactivate the superadmin", 409);

  await c.env.DB.prepare("UPDATE admins SET active = ? WHERE id = ?")
    .bind(body.active ? 1 : 0, target.id)
    .run();

  return json(c, { ok: true });
});

/** POST /api/admin/notify  { message, kind? } — broadcast to every rider. */
app.post("/api/admin/notify", async (c) => {
  if (!(await requireAdmin(c))) return fail(c, "Unauthorized", 401);

  const body = await readJson(c);
  if (!body?.message) return fail(c, "message is required", 400);

  // routeId NULL marks a broadcast, which /api/alerts shows to everyone.
  await c.env.DB.prepare(
    "INSERT INTO alerts (id, routeId, routeNumber, kind, message, createdAt) VALUES (?, NULL, NULL, ?, ?, ?)",
  )
    .bind(newId(), String(body.kind ?? "service"), String(body.message), Date.now())
    .run();

  return json(c, { ok: true });
});

/**
 * POST /api/admin/bootstrap-superadmin  { email, password, name }
 * Authorization: Bearer <ADMIN_KEY>
 *
 * One-time setup. Refuses once a superadmin exists, so it cannot be used to
 * take over a deployment that is already running.
 */
app.post("/api/admin/bootstrap-superadmin", async (c) => {
  const presented = bearerToken(c.req.header("Authorization") ?? null);
  if (!c.env.ADMIN_KEY || presented !== c.env.ADMIN_KEY) {
    return fail(c, "Unauthorized", 401);
  }

  const body = await readJson(c);
  if (!body?.email || !body?.password || !body?.name) {
    return fail(c, "email, password and name are required", 400);
  }

  const existing = await one<{ n: number }>(
    c.env.DB.prepare("SELECT COUNT(*) AS n FROM admins WHERE role = 'superadmin'"),
  );
  if ((existing?.n ?? 0) > 0) return fail(c, "A superadmin already exists", 409);

  const id = newId();
  await c.env.DB.prepare(
    "INSERT INTO admins (id, email, passwordHash, name, role, active, createdAt) VALUES (?, ?, ?, ?, 'superadmin', 1, ?)",
  )
    .bind(
      id,
      String(body.email).trim().toLowerCase(),
      await hashPassword(String(body.password)),
      String(body.name),
      Date.now(),
    )
    .run();

  return json(c, { id }, 201);
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
