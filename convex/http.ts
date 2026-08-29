import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { internal, api } from "./_generated/api";
import { Id } from "./_generated/dataModel";
import { bearerToken, sha256Hex } from "./lib/auth";

const http = httpRouter();

/**
 * Browsers enforce CORS on the Flutter web build. Set ALLOWED_ORIGIN to the
 * deployed web origin in production; the default is permissive so local
 * `flutter run -d chrome` (which picks a random port) works out of the box.
 */
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN ?? "*";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Max-Age": "86400",
  Vary: "Origin",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

function fail(message: string, status: number) {
  return json({ error: message }, status);
}

const preflight = httpAction(async () => new Response(null, { status: 204, headers: corsHeaders }));

/** Cryptographically random opaque token, URL-safe. */
function newToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Resolves the caller's subject from the Authorization header. */
async function requireSubject(ctx: any, request: Request): Promise<string | null> {
  const token = bearerToken(request.headers.get("Authorization"));
  if (!token) return null;
  return await ctx.runQuery(internal.users.subjectForToken, { token });
}

// ---------------------------------------------------------------------------
// Device ingest (ESP32)
// ---------------------------------------------------------------------------

/**
 * POST /api/ingest
 * Authorization: Bearer <device token>
 * { deviceId, lat, lng, speedKph?, headingDeg?, satellites?, hdop?,
 *   recordedAt?, firmware?, rssi? }
 *
 * Also accepts { batch: [ ...fixes ] } so a tracker that lost WiFi can flush
 * its buffer in one request when it reconnects.
 */
http.route({
  path: "/api/ingest",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const token = bearerToken(request.headers.get("Authorization"));
    if (!token) return fail("Missing bearer token", 401);

    let body: any;
    try {
      body = await request.json();
    } catch {
      return fail("Body must be JSON", 400);
    }

    const deviceId = String(body.deviceId ?? "");
    if (!deviceId) return fail("deviceId is required", 400);

    const device = await ctx.runQuery(internal.devices.verify, { deviceId, token });
    if (!device) return fail("Invalid device credentials", 401);

    const fixes: any[] = Array.isArray(body.batch) ? body.batch : [body];
    if (fixes.length > 60) return fail("Batch too large (max 60)", 413);

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

      // u-blox reports HDOP, not metres. The ~5 m/HDOP rule of thumb is
      // enough to tell a clean fix from a poor one.
      const hdop = Number(fix.hdop);
      const accuracyM = Number.isFinite(hdop) ? hdop * 5 : undefined;

      const r = await ctx.runMutation(internal.telemetry.ingest, {
        routeId: device.routeId,
        lat,
        lng,
        speedKph: Number.isFinite(Number(fix.speedKph)) ? Number(fix.speedKph) : undefined,
        headingDeg: Number.isFinite(Number(fix.headingDeg)) ? Number(fix.headingDeg) : undefined,
        accuracyM,
        satellites: Number.isFinite(Number(fix.satellites)) ? Number(fix.satellites) : undefined,
        recordedAt,
        source: "device" as const,
        deviceId,
      });
      results.push(r);
    }

    await ctx.runMutation(internal.devices.touch, {
      deviceId,
      firmware: body.firmware ? String(body.firmware) : undefined,
      rssi: Number.isFinite(Number(body.rssi)) ? Number(body.rssi) : undefined,
    });

    // The device syncs its clock from this so buffered fixes get sane stamps.
    return json({ ok: true, serverTime: now, results });
  }),
});
http.route({ path: "/api/ingest", method: "OPTIONS", handler: preflight });

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

/**
 * POST /api/auth/google  { idToken }
 *
 * Verifies a Google ID token and issues an app session.
 */
http.route({
  path: "/api/auth/google",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const clientIds = (process.env.GOOGLE_CLIENT_IDS ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    if (clientIds.length === 0) {
      return fail("GOOGLE_CLIENT_IDS is not configured on the backend", 503);
    }

    let body: any;
    try {
      body = await request.json();
    } catch {
      return fail("Body must be JSON", 400);
    }
    const idToken = String(body.idToken ?? "");
    if (!idToken) return fail("idToken is required", 400);

    const res = await fetch(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(idToken)}`,
    );
    if (!res.ok) return fail("Google rejected the ID token", 401);
    const claims: any = await res.json();

    if (!clientIds.includes(claims.aud)) {
      return fail("ID token was issued for a different client", 401);
    }
    if (claims.iss !== "accounts.google.com" && claims.iss !== "https://accounts.google.com") {
      return fail("Unexpected token issuer", 401);
    }
    if (Number(claims.exp) * 1000 < Date.now()) {
      return fail("ID token has expired", 401);
    }

    const token = newToken();
    await ctx.runMutation(internal.users.upsertAndIssueSession, {
      subject: `google:${claims.sub}`,
      email: claims.email,
      name: claims.name,
      pictureUrl: claims.picture,
      isGuest: false,
      tokenHash: await sha256Hex(token),
    });

    return json({ token, subject: `google:${claims.sub}` });
  }),
});
http.route({ path: "/api/auth/google", method: "OPTIONS", handler: preflight });

/**
 * POST /api/auth/guest
 *
 * Issues an anonymous session so guests get a stable identity for their
 * linked bus and rider sharing without signing in.
 */
http.route({
  path: "/api/auth/guest",
  method: "POST",
  handler: httpAction(async (ctx) => {
    const token = newToken();
    const subject = `guest:${newToken().slice(0, 24)}`;
    await ctx.runMutation(internal.users.upsertAndIssueSession, {
      subject,
      isGuest: true,
      tokenHash: await sha256Hex(token),
    });
    return json({ token, subject });
  }),
});
http.route({ path: "/api/auth/guest", method: "OPTIONS", handler: preflight });

/** POST /api/auth/signout */
http.route({
  path: "/api/auth/signout",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const token = bearerToken(request.headers.get("Authorization"));
    if (token) {
      await ctx.runMutation(internal.users.signOut, { tokenHash: await sha256Hex(token) });
    }
    return json({ ok: true });
  }),
});
http.route({ path: "/api/auth/signout", method: "OPTIONS", handler: preflight });

// ---------------------------------------------------------------------------
// App reads
// ---------------------------------------------------------------------------

/** GET /api/me */
http.route({
  path: "/api/me",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);
    const profile = await ctx.runQuery(internal.users.profileFor, { subject });
    if (!profile) return fail("Unknown user", 404);
    return json(profile);
  }),
});
http.route({ path: "/api/me", method: "OPTIONS", handler: preflight });

/** POST /api/me  { notifyLeadMinutes?, linkedRouteId? } */
http.route({
  path: "/api/me",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);

    let body: any;
    try {
      body = await request.json();
    } catch {
      return fail("Body must be JSON", 400);
    }

    await ctx.runMutation(internal.users.updatePreferences, {
      subject,
      notifyLeadMinutes:
        body.notifyLeadMinutes !== undefined ? Number(body.notifyLeadMinutes) : undefined,
      linkedRouteId:
        body.linkedRouteId !== undefined
          ? (body.linkedRouteId as Id<"routes">)
          : undefined,
    });

    return json(await ctx.runQuery(internal.users.profileFor, { subject }));
  }),
});

/**
 * GET /api/routes
 *
 * The full route list sits behind sign-in; guests only get their linked bus.
 */
http.route({
  path: "/api/routes",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);

    const profile = await ctx.runQuery(internal.users.profileFor, { subject });
    if (!profile) return fail("Unknown user", 404);

    const all = await ctx.runQuery(api.routes.list, {});
    if (!profile.isGuest) return json(all);

    const linkedId = profile.linkedRoute?.id ?? null;
    return json({
      ...all,
      routes: all.routes.filter((r: any) => r.id === linkedId),
      restricted: true,
    });
  }),
});
http.route({ path: "/api/routes", method: "OPTIONS", handler: preflight });

/** GET /api/route?id=<routeId> */
http.route({
  path: "/api/route",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);

    const id = new URL(request.url).searchParams.get("id");
    if (!id) return fail("id is required", 400);

    const detail = await ctx.runQuery(api.routes.detail, { routeId: id as Id<"routes"> });
    if (!detail) return fail("Unknown route", 404);

    const sharing = await ctx.runQuery(internal.riders.sharingState, {
      riderId: subject,
      routeId: id as Id<"routes">,
    });

    return json({ ...detail, sharing: sharing.active, riders: sharing.count });
  }),
});
http.route({ path: "/api/route", method: "OPTIONS", handler: preflight });

/** GET /api/alerts */
http.route({
  path: "/api/alerts",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);
    return json(await ctx.runQuery(internal.alerts.feedFor, { subject }));
  }),
});
http.route({ path: "/api/alerts", method: "OPTIONS", handler: preflight });

/** POST /api/alerts/read */
http.route({
  path: "/api/alerts/read",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);
    await ctx.runMutation(internal.alerts.markRead, { subject });
    return json({ ok: true });
  }),
});
http.route({ path: "/api/alerts/read", method: "OPTIONS", handler: preflight });

// ---------------------------------------------------------------------------
// Rider-assisted tracking
// ---------------------------------------------------------------------------

/** POST /api/share  { routeId, active } */
http.route({
  path: "/api/share",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);

    let body: any;
    try {
      body = await request.json();
    } catch {
      return fail("Body must be JSON", 400);
    }
    if (!body.routeId) return fail("routeId is required", 400);

    const result = await ctx.runMutation(internal.riders.setSharing, {
      riderId: subject,
      routeId: body.routeId as Id<"routes">,
      active: !!body.active,
    });
    return json(result);
  }),
});
http.route({ path: "/api/share", method: "OPTIONS", handler: preflight });

/** POST /api/share/fix  { routeId, lat, lng, speedKph?, headingDeg?, accuracyM? } */
http.route({
  path: "/api/share/fix",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const subject = await requireSubject(ctx, request);
    if (!subject) return fail("Unauthorized", 401);

    let body: any;
    try {
      body = await request.json();
    } catch {
      return fail("Body must be JSON", 400);
    }

    const lat = Number(body.lat);
    const lng = Number(body.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      return fail("lat and lng are required", 400);
    }

    try {
      const r = await ctx.runMutation(api.telemetry.submitRiderFix, {
        routeId: body.routeId as Id<"routes">,
        riderId: subject,
        lat,
        lng,
        speedKph: Number.isFinite(Number(body.speedKph)) ? Number(body.speedKph) : undefined,
        headingDeg: Number.isFinite(Number(body.headingDeg))
          ? Number(body.headingDeg)
          : undefined,
        accuracyM: Number.isFinite(Number(body.accuracyM)) ? Number(body.accuracyM) : undefined,
        recordedAt: Date.now(),
      });
      return json(r);
    } catch (e: any) {
      return fail(e?.message ?? "Rejected", 409);
    }
  }),
});
http.route({ path: "/api/share/fix", method: "OPTIONS", handler: preflight });

// ---------------------------------------------------------------------------
// Admin (device provisioning)
// ---------------------------------------------------------------------------

/**
 * POST /api/admin/devices  { deviceId, routeId, label? }
 * Authorization: Bearer <ADMIN_KEY>
 *
 * Returns the plaintext device token exactly once — it is only stored hashed.
 */
http.route({
  path: "/api/admin/devices",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const adminKey = process.env.ADMIN_KEY;
    if (!adminKey) return fail("ADMIN_KEY is not configured", 503);
    if (bearerToken(request.headers.get("Authorization")) !== adminKey) {
      return fail("Unauthorized", 401);
    }

    let body: any;
    try {
      body = await request.json();
    } catch {
      return fail("Body must be JSON", 400);
    }
    if (!body.deviceId || !body.routeId) {
      return fail("deviceId and routeId are required", 400);
    }

    const deviceToken = newToken();
    const result = await ctx.runMutation(internal.devices.provision, {
      deviceId: String(body.deviceId),
      routeId: body.routeId as Id<"routes">,
      tokenHash: await sha256Hex(deviceToken),
      label: body.label ? String(body.label) : undefined,
    });

    return json({ ...result, token: deviceToken });
  }),
});
http.route({ path: "/api/admin/devices", method: "OPTIONS", handler: preflight });

export default http;
