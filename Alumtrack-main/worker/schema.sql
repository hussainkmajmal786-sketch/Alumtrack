-- Alumtrack schema for Cloudflare D1 (SQLite).
--
-- Translated from the Convex document schema. Three differences are
-- structural rather than cosmetic, and the rest of the backend depends on
-- them:
--
--  1. Convex generates opaque document ids; here every table carries an
--     explicit TEXT `id` primary key holding the same style of value, so
--     ids already issued by Convex survive the data migration and any id
--     stored in a client, a flashed device, or an existing session keeps
--     working.
--
--  2. Convex's `v.optional()` becomes a nullable column. SQLite has no
--     boolean type, so `v.boolean()` becomes INTEGER 0/1 with a CHECK.
--
--  3. `routes.roadPolyline` was an array of {lat,lng} objects. SQLite has
--     no array type, so it is stored as a JSON string and parsed at the
--     edge. It is only ever read and written whole, never queried into, so
--     nothing is lost by not normalising it into its own table.
--
-- Every Convex `.index(...)` has a matching CREATE INDEX below, in the same
-- column order. That order is not incidental: SQLite can only use a
-- composite index for a query whose predicates form a prefix of it, which
-- is the same rule Convex's indexes follow.

PRAGMA foreign_keys = ON;

-- A named route, e.g. "Route 12 — Kottayam ⇄ CEK Kidangoor".
CREATE TABLE IF NOT EXISTS routes (
  id                    TEXT PRIMARY KEY,
  number                TEXT NOT NULL,
  name                  TEXT NOT NULL,
  active                INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  -- Scheduled arrival at the final stop, "HH:mm" local time. Display only.
  scheduledArrival      TEXT,
  -- JSON array of {lat,lng}: the real road path from the routing engine.
  -- NULL until first fetched; the map falls back to straight stop-to-stop
  -- lines, so a routing-service outage never blocks rendering.
  roadPolyline          TEXT,
  roadPolylineFetchedAt INTEGER,
  createdAt             INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS routes_by_number ON routes (number);

-- Ordered stops along a route. `seq` is 0-based and dense.
CREATE TABLE IF NOT EXISTS stops (
  id          TEXT PRIMARY KEY,
  routeId     TEXT NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  seq         INTEGER NOT NULL,
  name        TEXT NOT NULL,
  lat         REAL NOT NULL,
  lng         REAL NOT NULL,
  -- Scheduled time at this stop, "HH:mm" local. Used for delay estimates.
  scheduledAt TEXT,
  createdAt   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS stops_by_route ON stops (routeId);
CREATE INDEX IF NOT EXISTS stops_by_route_seq ON stops (routeId, seq);

-- A physical ESP32 tracker bolted to a bus.
CREATE TABLE IF NOT EXISTS devices (
  id        TEXT PRIMARY KEY,
  deviceId  TEXT NOT NULL,
  routeId   TEXT NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  label     TEXT,
  -- sha256 of the provisioning token. The plaintext is shown once at
  -- provisioning time and never stored.
  tokenHash TEXT NOT NULL,
  revoked   INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1)),
  lastSeen  INTEGER,
  -- Diagnostics reported on the last successful ingest.
  firmware  TEXT,
  rssi      INTEGER,
  createdAt INTEGER NOT NULL
);
-- UNIQUE, not just indexed: `devices.verify` resolves a device by deviceId
-- with `.unique()` in Convex, which throws on duplicates. The constraint
-- makes that guarantee the database's job rather than the caller's.
CREATE UNIQUE INDEX IF NOT EXISTS devices_by_deviceId ON devices (deviceId);
CREATE INDEX IF NOT EXISTS devices_by_route ON devices (routeId);

-- Time-series GPS fixes, written by devices and rider-assisted phones.
CREATE TABLE IF NOT EXISTS positions (
  id         TEXT PRIMARY KEY,
  routeId    TEXT NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  lat        REAL NOT NULL,
  lng        REAL NOT NULL,
  speedKph   REAL,
  headingDeg REAL,
  accuracyM  REAL,
  satellites INTEGER,
  -- Epoch millis the fix was taken (device clock), not when it arrived.
  recordedAt INTEGER NOT NULL,
  source     TEXT NOT NULL CHECK (source IN ('device', 'rider')),
  deviceId   TEXT,
  riderId    TEXT,
  createdAt  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS positions_by_route_recordedAt
  ON positions (routeId, recordedAt);
CREATE INDEX IF NOT EXISTS positions_by_route_source_recordedAt
  ON positions (routeId, source, recordedAt);

-- The current consolidated state of each route, recomputed on ingest so
-- reads stay O(1) instead of scanning the positions time series.
CREATE TABLE IF NOT EXISTS liveState (
  id           TEXT PRIMARY KEY,
  -- UNIQUE because there is exactly one live state per route; the Convex
  -- code reads it with `.unique()` and upserts in place.
  routeId      TEXT NOT NULL UNIQUE REFERENCES routes (id) ON DELETE CASCADE,
  lat          REAL NOT NULL,
  lng          REAL NOT NULL,
  speedKph     REAL,
  headingDeg   REAL,
  -- 0..1 along the route polyline.
  progress     REAL NOT NULL,
  nextStopSeq  INTEGER NOT NULL,
  etaSeconds   INTEGER,
  -- Positive = running late, in seconds. Negative = early.
  delaySeconds INTEGER,
  updatedAt    INTEGER NOT NULL,
  source       TEXT NOT NULL CHECK (source IN ('device', 'rider')),
  accuracyM    REAL
);
CREATE INDEX IF NOT EXISTS liveState_by_route ON liveState (routeId);

-- A rider who opted in to share their phone's location.
CREATE TABLE IF NOT EXISTS riderShares (
  id        TEXT PRIMARY KEY,
  routeId   TEXT NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  -- UNIQUE: a rider has at most one share at a time; switching routes
  -- moves it rather than accumulating rows.
  riderId   TEXT NOT NULL UNIQUE,
  startedAt INTEGER NOT NULL,
  lastSeen  INTEGER NOT NULL,
  active    INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
);
CREATE INDEX IF NOT EXISTS riderShares_by_route_active
  ON riderShares (routeId, active);
CREATE INDEX IF NOT EXISTS riderShares_by_riderId ON riderShares (riderId);

CREATE TABLE IF NOT EXISTS alerts (
  id          TEXT PRIMARY KEY,
  -- NULL routeId means a broadcast alert, shown to everyone.
  routeId     TEXT REFERENCES routes (id) ON DELETE CASCADE,
  -- Denormalised so rendering the feed never has to fetch each route.
  -- Alerts are immutable history, so this cannot drift meaningfully.
  routeNumber TEXT,
  kind        TEXT NOT NULL
                CHECK (kind IN ('arriving', 'delay', 'signal', 'service', 'stop')),
  message     TEXT NOT NULL,
  createdAt   INTEGER NOT NULL,
  -- Set only for kind = 'stop': which stop (by seq) this announces, so the
  -- alert generator can tell "already announced up to seq 3" rather than
  -- relying on a cooldown window that would miss a bus passing several
  -- stops in quick succession.
  stopSeq     INTEGER
);
CREATE INDEX IF NOT EXISTS alerts_by_createdAt ON alerts (createdAt);
CREATE INDEX IF NOT EXISTS alerts_by_route_createdAt ON alerts (routeId, createdAt);
-- Not in the Convex schema: the stop-alert watermark query filters by kind
-- within a route and takes the newest. Without this it degrades to a scan
-- of every alert on the route as that history grows.
CREATE INDEX IF NOT EXISTS alerts_by_route_kind_createdAt
  ON alerts (routeId, kind, createdAt);

CREATE TABLE IF NOT EXISTS users (
  id                TEXT PRIMARY KEY,
  -- Google `sub`, "guest:<uuid>", or "email:<lowercased email>".
  subject           TEXT NOT NULL UNIQUE,
  email             TEXT,
  name              TEXT,
  pictureUrl        TEXT,
  isGuest           INTEGER NOT NULL DEFAULT 0 CHECK (isGuest IN (0, 1)),
  -- Set only for subject = "email:...". PBKDF2, never the plaintext.
  passwordHash      TEXT,
  linkedRouteId     TEXT REFERENCES routes (id) ON DELETE SET NULL,
  -- A stop on linkedRouteId the admin pinned this student to. Cleared
  -- whenever linkedRouteId changes, since a stop only means anything
  -- within its own route.
  linkedStopId      TEXT REFERENCES stops (id) ON DELETE SET NULL,
  -- Minutes before arrival to notify. One of 2, 5, 10.
  notifyLeadMinutes INTEGER NOT NULL DEFAULT 5,
  createdAt         INTEGER NOT NULL,
  lastSeenAt        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS users_by_subject ON users (subject);
-- Not in the Convex schema: the alert generator groups every user by
-- linkedRouteId on each run. Without this it is a full table scan per tick.
CREATE INDEX IF NOT EXISTS users_by_linkedRoute ON users (linkedRouteId);

-- Per-user read state for alerts, so the unread badge is per person.
CREATE TABLE IF NOT EXISTS alertReads (
  id          TEXT PRIMARY KEY,
  subject     TEXT NOT NULL UNIQUE,
  readThrough INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS alertReads_by_subject ON alertReads (subject);

-- Staff accounts: 1 superadmin plus up to 4 admins. Separate from `users`
-- because they authenticate with email + password, not Google.
CREATE TABLE IF NOT EXISTS admins (
  id           TEXT PRIMARY KEY,
  email        TEXT NOT NULL UNIQUE,
  passwordHash TEXT NOT NULL,
  name         TEXT NOT NULL,
  role         TEXT NOT NULL CHECK (role IN ('admin', 'superadmin')),
  active       INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  createdAt    INTEGER NOT NULL,
  lastLoginAt  INTEGER
);
CREATE INDEX IF NOT EXISTS admins_by_email ON admins (email);

-- A rider's rating of one completed trip.
CREATE TABLE IF NOT EXISTS feedback (
  id          TEXT PRIMARY KEY,
  routeId     TEXT NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  subject     TEXT NOT NULL,
  rating      INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment     TEXT,
  -- The final stop's liveState.updatedAt at submission time, so the same
  -- completed trip is never prompted for (or accepted) twice.
  tripEndedAt INTEGER NOT NULL,
  createdAt   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS feedback_by_route_createdAt
  ON feedback (routeId, createdAt);
-- UNIQUE enforces the one-rating-per-trip rule in the database rather than
-- leaving it to a check-then-insert race in the handler.
CREATE UNIQUE INDEX IF NOT EXISTS feedback_by_subject_trip
  ON feedback (subject, routeId, tripEndedAt);

-- Opaque bearer sessions. Only the hash is stored, so a database leak does
-- not hand out usable sessions.
CREATE TABLE IF NOT EXISTS sessions (
  id        TEXT PRIMARY KEY,
  tokenHash TEXT NOT NULL UNIQUE,
  subject   TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  expiresAt INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_by_tokenHash ON sessions (tokenHash);
CREATE INDEX IF NOT EXISTS sessions_by_subject ON sessions (subject);
-- Not in the Convex schema: session pruning sweeps by expiry.
CREATE INDEX IF NOT EXISTS sessions_by_expiresAt ON sessions (expiresAt);
