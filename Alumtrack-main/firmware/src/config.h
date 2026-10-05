#pragma once

// Tuning knobs for the tracker. Values here are safe defaults for a campus
// shuttle running a 30-45 minute loop on intermittent Wi-Fi.

// --- GPS wiring -----------------------------------------------------------
// NEO-6M TX -> ESP32 GPIO16 (RX2), NEO-6M RX -> ESP32 GPIO17 (TX2).
static constexpr int GPS_RX_PIN = 16;
static constexpr int GPS_TX_PIN = 17;
static constexpr uint32_t GPS_BAUD = 9600;

// --- Reporting cadence ----------------------------------------------------
// Riders care about a moving bus; a parked one only needs a heartbeat.
// 10s while moving is a deliberate halving of the original 5s. At road
// speed that is ~110 m between fixes, which the app's marker animation
// smooths over anyway, and it halves the backend ingest calls — the single
// largest consumer of the deployment's function-call quota.
static constexpr uint32_t SEND_INTERVAL_MOVING_MS = 10000;
// A parked bus needs only a heartbeat to prove the tracker is alive.
static constexpr uint32_t SEND_INTERVAL_IDLE_MS = 60000;

// Below this the vehicle is treated as stationary.
static constexpr double MOVING_SPEED_KPH = 4.0;

// Skip a send when the bus has not moved at least this far and the idle
// heartbeat is not yet due — saves data on a bus waiting at a stop.
static constexpr double MIN_MOVE_METRES = 15.0;

// --- Fix quality ----------------------------------------------------------
// u-blox HDOP above this is a poor fix (urban canyon, cold start). Still
// buffered, but flagged so the server can down-weight it.
static constexpr double MAX_USABLE_HDOP = 6.0;
static constexpr uint32_t MIN_SATELLITES = 4;

// --- Offline buffering ----------------------------------------------------
// Fixes captured while Wi-Fi is down, flushed on reconnect. 180 entries at
// the moving cadence is ~15 minutes of history; each entry is 32 bytes.
static constexpr size_t BUFFER_CAPACITY = 180;

// Convex caps a batch at 60; keep headroom under the HTTP body limit.
static constexpr size_t MAX_BATCH = 40;

// --- Networking -----------------------------------------------------------
static constexpr uint32_t WIFI_CONNECT_TIMEOUT_MS = 20000;
static constexpr uint32_t HTTP_TIMEOUT_MS = 10000;

// Reconnect backoff, doubling from min to max so a bus out of coverage does
// not spin the radio flat.
static constexpr uint32_t WIFI_RETRY_MIN_MS = 3000;
static constexpr uint32_t WIFI_RETRY_MAX_MS = 60000;

// Backoff after a failed POST. Without this a backend outage would block the
// loop for the HTTP timeout on every pass and overflow the GPS UART.
static constexpr uint32_t FLUSH_RETRY_MIN_MS = 2000;
static constexpr uint32_t FLUSH_RETRY_MAX_MS = 60000;

// --- Watchdog -------------------------------------------------------------
// Generous: a cold GPS fix plus a slow DNS lookup can legitimately take a
// while. This only catches a genuinely wedged loop.
static constexpr uint32_t WATCHDOG_TIMEOUT_S = 120;

// --- Status LED -----------------------------------------------------------
// Most ESP32 devkits wire the onboard LED to GPIO2.
static constexpr int STATUS_LED_PIN = 2;

static constexpr const char *FIRMWARE_VERSION = "1.0.0";
