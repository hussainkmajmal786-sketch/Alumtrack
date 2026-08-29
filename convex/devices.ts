import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import { sha256Hex, timingSafeEqualHex } from "./lib/auth";

/**
 * Authenticates an ESP32 tracker.
 *
 * Returns the route the device is bound to, so a compromised token can only
 * ever move the one bus it was issued for.
 */
export const verify = internalQuery({
  args: { deviceId: v.string(), token: v.string() },
  handler: async (ctx, args) => {
    const device = await ctx.db
      .query("devices")
      .withIndex("by_deviceId", (q) => q.eq("deviceId", args.deviceId))
      .unique();

    if (!device || device.revoked) return null;

    const presented = await sha256Hex(args.token);
    if (!timingSafeEqualHex(presented, device.tokenHash)) return null;

    return { deviceId: device.deviceId, routeId: device.routeId };
  },
});

export const touch = internalMutation({
  args: {
    deviceId: v.string(),
    firmware: v.optional(v.string()),
    rssi: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const device = await ctx.db
      .query("devices")
      .withIndex("by_deviceId", (q) => q.eq("deviceId", args.deviceId))
      .unique();
    if (!device) return;
    await ctx.db.patch(device._id, {
      lastSeen: Date.now(),
      firmware: args.firmware ?? device.firmware,
      rssi: args.rssi ?? device.rssi,
    });
  },
});

/**
 * Registers a tracker against a route.
 *
 * The caller generates the token and passes only its hash; the plaintext is
 * flashed into the device and never stored here.
 */
export const provision = internalMutation({
  args: {
    deviceId: v.string(),
    routeId: v.id("routes"),
    tokenHash: v.string(),
    label: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("devices")
      .withIndex("by_deviceId", (q) => q.eq("deviceId", args.deviceId))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        routeId: args.routeId,
        tokenHash: args.tokenHash,
        label: args.label ?? existing.label,
        revoked: false,
      });
      return { deviceId: args.deviceId, rotated: true };
    }

    await ctx.db.insert("devices", {
      deviceId: args.deviceId,
      routeId: args.routeId,
      tokenHash: args.tokenHash,
      label: args.label,
      revoked: false,
    });
    return { deviceId: args.deviceId, rotated: false };
  },
});

export const revoke = internalMutation({
  args: { deviceId: v.string() },
  handler: async (ctx, args) => {
    const device = await ctx.db
      .query("devices")
      .withIndex("by_deviceId", (q) => q.eq("deviceId", args.deviceId))
      .unique();
    if (!device) throw new Error("Unknown device");
    await ctx.db.patch(device._id, { revoked: true });
    return { ok: true };
  },
});
