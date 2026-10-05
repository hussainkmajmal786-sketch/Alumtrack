/**
 * Scheduled jobs, ported from convex/crons.ts + maintenance.ts + riders.ts.
 *
 * Workers routes every cron trigger into one handler, so the expression is
 * what selects the job. The cadences here are the post-overage ones, not the
 * originals: at 60s each, these two crons alone burned ~87k calls a month
 * doing mostly nothing.
 */

import { all, newId, one, type AlertRow, type Env, type LiveStateRow, type RouteRow, type StopRow, type UserRow } from "./lib/db";
import { signalQuality, STALE_AFTER_MS } from "./telemetry";

const POSITION_RETENTION_MS = 1000 * 60 * 60 * 24 * 7; // 7 days
const PRUNE_BATCH = 400;

/** Don't re-announce the same condition on every tick. */
const ALERT_COOLDOWN_MS = 1000 * 60 * 20;
const LATE_THRESHOLD_S = 120;

function minutes(seconds: number): number {
  return Math.max(1, Math.round(seconds / 60));
}

export async function runScheduled(cron: string, env: Env): Promise<void> {
  switch (cron) {
    case "*/2 * * * *":
      await generateAlerts(env);
      return;
    case "*/10 * * * *":
      await expireStaleShares(env);
      return;
    case "0 */6 * * *":
      await prunePositions(env);
      await pruneSessions(env);
      return;
  }
}

/**
 * Marks shares inactive once their phone has gone quiet.
 *
 * Only tidies rows: the rider-count queries already filter by staleness at
 * read time, so a stale share stops being *counted* the moment it goes
 * stale regardless of this job.
 */
async function expireStaleShares(env: Env): Promise<void> {
  const cutoff = Date.now() - STALE_AFTER_MS;
  await env.DB.prepare(
    "UPDATE riderShares SET active = 0 WHERE active = 1 AND lastSeen < ?",
  )
    .bind(cutoff)
    .run();
}

/** Deletes position rows past the retention window, bounded per run. */
async function prunePositions(env: Env): Promise<void> {
  const cutoff = Date.now() - POSITION_RETENTION_MS;
  await env.DB.prepare(
    `DELETE FROM positions
      WHERE id IN (SELECT id FROM positions WHERE recordedAt < ? LIMIT ?)`,
  )
    .bind(cutoff, PRUNE_BATCH)
    .run();
}

/** Clears expired sessions. */
async function pruneSessions(env: Env): Promise<void> {
  await env.DB.prepare("DELETE FROM sessions WHERE expiresAt < ?").bind(Date.now()).run();
}

/**
 * Derives rider-facing alerts from live state.
 *
 * On a cron rather than on ingest so a bus reporting every few seconds
 * cannot spam the feed.
 */
async function generateAlerts(env: Env): Promise<void> {
  const now = Date.now();
  const routes = await all<RouteRow>(env.DB.prepare("SELECT * FROM routes WHERE active = 1"));

  // Read once: the arrival check needs every user's lead-time preference,
  // and re-reading per route would scan the table N times.
  const users = await all<UserRow>(
    env.DB.prepare("SELECT linkedRouteId, notifyLeadMinutes FROM users WHERE linkedRouteId IS NOT NULL"),
  );
  const leadsByRoute = new Map<string, Set<number>>();
  for (const u of users) {
    if (!u.linkedRouteId) continue;
    const set = leadsByRoute.get(u.linkedRouteId) ?? new Set<number>();
    set.add(u.notifyLeadMinutes);
    leadsByRoute.set(u.linkedRouteId, set);
  }

  for (const route of routes) {
    const live = await one<LiveStateRow>(
      env.DB.prepare("SELECT * FROM liveState WHERE routeId = ?").bind(route.id),
    );

    const recent = await all<AlertRow>(
      env.DB.prepare(
        "SELECT * FROM alerts WHERE routeId = ? ORDER BY createdAt DESC LIMIT 10",
      ).bind(route.id),
    );

    const publishedRecently = (kind: AlertRow["kind"]) =>
      recent.some((a) => a.kind === kind && now - a.createdAt < ALERT_COOLDOWN_MS);

    const insert = (kind: AlertRow["kind"], message: string, stopSeq: number | null = null) =>
      env.DB.prepare(
        `INSERT INTO alerts (id, routeId, routeNumber, kind, message, createdAt, stopSeq)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
        .bind(newId(), route.id, route.number, kind, message, now, stopSeq)
        .run();

    const quality = signalQuality(live, now);

    if (quality === "offline") {
      if (!publishedRecently("signal")) {
        await insert("signal", `${route.number} stopped reporting its location`);
      }
      continue;
    }

    if (!live) continue;

    // Arrival heads-up, honouring each rider's lead-time preference.
    if (live.etaSeconds !== null && !publishedRecently("arriving")) {
      const leads = leadsByRoute.get(route.id) ?? new Set<number>();
      for (const lead of leads) {
        const window = lead * 60;
        if (live.etaSeconds <= window && live.etaSeconds > window - 120) {
          await insert("arriving", `Your bus is ${minutes(live.etaSeconds)} minutes away`);
          break;
        }
      }
    }

    const stops = await all<StopRow>(
      env.DB.prepare("SELECT * FROM stops WHERE routeId = ? ORDER BY seq ASC").bind(route.id),
    );

    if (live.delaySeconds !== null && live.delaySeconds > LATE_THRESHOLD_S && !publishedRecently("delay")) {
      const nextStop = stops.find((s) => s.seq === live.nextStopSeq);
      await insert(
        "delay",
        `${route.number} delayed ${minutes(live.delaySeconds)} min${nextStop ? ` near ${nextStop.name}` : ""}`,
      );
    }

    // Announce every stop passed since the last tick. `nextStopSeq` is the
    // stop being headed toward, so anything below it — and above the last
    // announced seq — was passed since we last looked. Looping rather than
    // announcing only the latest handles a bus covering several stops
    // between ticks without silently skipping the ones in between.
    //
    // Queried by kind rather than reusing `recent`: a burst of other alerts
    // could push the last "stop" row out of a 10-row window, which would
    // re-announce stops already covered.
    const lastStopAlert = await one<AlertRow>(
      env.DB.prepare(
        "SELECT * FROM alerts WHERE routeId = ? AND kind = 'stop' ORDER BY createdAt DESC LIMIT 1",
      ).bind(route.id),
    );
    const announcedThrough = lastStopAlert?.stopSeq ?? -1;

    for (const stop of stops) {
      if (stop.seq <= announcedThrough) continue;
      if (stop.seq >= live.nextStopSeq) break;
      await insert("stop", `${route.number} passed ${stop.name}`, stop.seq);
    }
  }
}
