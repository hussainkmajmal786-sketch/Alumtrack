#pragma once

// Copy this file to `secrets.h` and fill in the values for each tracker.
// `secrets.h` is gitignored — never commit a real device token.

// --- Identity -------------------------------------------------------------
// Must match the deviceId you registered via POST /api/admin/devices.
#define DEVICE_ID "bus-12-a"

// The plaintext token returned by that provisioning call. It is shown once
// and stored only as a hash on the server, so keep a copy when you issue it.
#define DEVICE_TOKEN "replace-me"

// --- Network --------------------------------------------------------------
// The Wi-Fi the bus provides (onboard router or the driver's hotspot).
#define WIFI_SSID "bus-wifi"
#define WIFI_PASSWORD "replace-me"

// Optional second network, tried when the primary is unavailable — useful so
// a bus parked in the depot can still report. Leave SSID empty to disable.
#define WIFI_SSID_FALLBACK ""
#define WIFI_PASSWORD_FALLBACK ""

// --- Backend --------------------------------------------------------------
// Convex HTTP Actions origin. Note this is the `.convex.site` host, NOT the
// `.convex.cloud` one used by the Convex client SDKs.
#define INGEST_URL "https://your-deployment.convex.site/api/ingest"
