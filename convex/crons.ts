import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Phones stop reporting without a clean "stop sharing" (app killed, screen
// locked, tab closed), so the active-rider count needs sweeping.
crons.interval(
  "expire stale rider shares",
  { seconds: 60 },
  internal.riders.expireStaleShares,
);

// Emit arrival / delay / signal alerts from the current live state.
crons.interval(
  "generate route alerts",
  { seconds: 60 },
  internal.maintenance.generateAlerts,
);

// Keep the raw time series bounded.
crons.interval(
  "prune old positions",
  { hours: 6 },
  internal.maintenance.prunePositions,
);

export default crons;
