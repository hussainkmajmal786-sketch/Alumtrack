import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  // A named route, e.g. "Route 12 — Kottayam ⇄ CEK Kidangoor".
  routes: defineTable({
    number: v.string(),
    name: v.string(),
    active: v.boolean(),
    // Scheduled arrival at the final stop, "HH:mm" local time. Display only.
    scheduledArrival: v.optional(v.string()),
  }).index("by_number", ["number"]),

  // Ordered stops along a route. `seq` is 0-based and dense.
  stops: defineTable({
    routeId: v.id("routes"),
    seq: v.number(),
    name: v.string(),
    lat: v.number(),
    lng: v.number(),
    // Scheduled time at this stop, "HH:mm" local. Used for delay estimates.
    scheduledAt: v.optional(v.string()),
  })
    .index("by_route", ["routeId"])
    .index("by_route_seq", ["routeId", "seq"]),

  // A physical ESP32 tracker bolted to a bus.
  devices: defineTable({
    deviceId: v.string(),
    routeId: v.id("routes"),
    label: v.optional(v.string()),
    // sha256 of the provisioning token. The plaintext token is shown once at
    // provisioning time and never stored.
    tokenHash: v.string(),
    revoked: v.boolean(),
    lastSeen: v.optional(v.number()),
    // Diagnostics reported by the device on its last successful ingest.
    firmware: v.optional(v.string()),
    rssi: v.optional(v.number()),
  })
    .index("by_deviceId", ["deviceId"])
    .index("by_route", ["routeId"]),

  // Time-series GPS fixes. Written by devices and by rider-assisted phones.
  positions: defineTable({
    routeId: v.id("routes"),
    lat: v.number(),
    lng: v.number(),
    speedKph: v.optional(v.number()),
    headingDeg: v.optional(v.number()),
    // Horizontal accuracy in metres, when the source reports it.
    accuracyM: v.optional(v.number()),
    satellites: v.optional(v.number()),
    // Epoch millis the fix was taken (device clock), not when it was received.
    recordedAt: v.number(),
    source: v.union(v.literal("device"), v.literal("rider")),
    // Set for source === "device".
    deviceId: v.optional(v.string()),
    // Set for source === "rider"; the anonymous rider session that sent it.
    riderId: v.optional(v.string()),
  })
    .index("by_route_recordedAt", ["routeId", "recordedAt"])
    .index("by_route_source_recordedAt", ["routeId", "source", "recordedAt"]),

  // The current consolidated state of each route, recomputed on ingest so
  // reads stay O(1) instead of scanning the positions time series.
  liveState: defineTable({
    routeId: v.id("routes"),
    lat: v.number(),
    lng: v.number(),
    speedKph: v.optional(v.number()),
    headingDeg: v.optional(v.number()),
    // 0..1 along the route polyline.
    progress: v.number(),
    // Index of the stop the bus is heading toward.
    nextStopSeq: v.number(),
    etaSeconds: v.optional(v.number()),
    // Positive = running late, in seconds. Negative = early.
    delaySeconds: v.optional(v.number()),
    updatedAt: v.number(),
    source: v.union(v.literal("device"), v.literal("rider")),
    accuracyM: v.optional(v.number()),
  }).index("by_route", ["routeId"]),

  // A rider who opted in to share their phone's location to improve accuracy.
  riderShares: defineTable({
    routeId: v.id("routes"),
    riderId: v.string(),
    startedAt: v.number(),
    lastSeen: v.number(),
    active: v.boolean(),
  })
    .index("by_route_active", ["routeId", "active"])
    .index("by_riderId", ["riderId"]),

  alerts: defineTable({
    routeId: v.optional(v.id("routes")),
    // Denormalised so rendering the feed never has to fetch each route.
    // Alerts are immutable history, so this cannot drift meaningfully.
    routeNumber: v.optional(v.string()),
    // Broadcast alerts (routeId unset) go to everyone.
    kind: v.union(
      v.literal("arriving"),
      v.literal("delay"),
      v.literal("signal"),
      v.literal("service"),
    ),
    message: v.string(),
    createdAt: v.number(),
  })
    .index("by_createdAt", ["createdAt"])
    .index("by_route_createdAt", ["routeId", "createdAt"]),

  users: defineTable({
    // Google `sub` claim, or "guest:<uuid>" for anonymous sessions.
    subject: v.string(),
    email: v.optional(v.string()),
    name: v.optional(v.string()),
    pictureUrl: v.optional(v.string()),
    isGuest: v.boolean(),
    linkedRouteId: v.optional(v.id("routes")),
    // Minutes before arrival to notify. One of 2, 5, 10.
    notifyLeadMinutes: v.number(),
    createdAt: v.number(),
    lastSeenAt: v.number(),
  }).index("by_subject", ["subject"]),

  // Per-user read state for alerts, so the unread badge is per person.
  alertReads: defineTable({
    subject: v.string(),
    readThrough: v.number(),
  }).index("by_subject", ["subject"]),

  // Opaque bearer sessions issued to the app. Only the hash is stored, so a
  // database leak does not hand out usable sessions.
  sessions: defineTable({
    tokenHash: v.string(),
    subject: v.string(),
    createdAt: v.number(),
    expiresAt: v.number(),
  })
    .index("by_tokenHash", ["tokenHash"])
    .index("by_subject", ["subject"]),
});
