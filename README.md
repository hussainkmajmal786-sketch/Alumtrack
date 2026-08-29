# Alumtrack

Live campus bus tracking for the Kottayam ⇄ College of Engineering Kidangoor
routes. An ESP32 tracker on each bus reports GPS over the bus Wi-Fi; a Convex
backend turns those fixes into arrival times; a Flutter app shows them on
Android, iOS and the web.

```
  ESP32 + NEO-6M          Convex                    Flutter app
 ┌────────────────┐     ┌──────────────────┐     ┌──────────────────┐
 │ GPS over UART  │     │ /api/ingest      │     │ Android          │
 │ ring buffer    │────▶│   snap to route  │◀────│ iOS              │
 │ HTTPS + token  │     │   ETA vs timetable│     │ Web              │
 └────────────────┘     │ /api/routes …    │     └──────────────────┘
       bus Wi-Fi        └──────────────────┘        polls every 5–10s
                                 ▲
                                 │ rider phones sharing location
                                 │ (only while the tracker is stale)
```

| Path | What it is |
| --- | --- |
| `convex/` | Backend: schema, queries, HTTP actions, crons |
| `app/` | Flutter client for Android, iOS and web |
| `firmware/` | PlatformIO project for the ESP32 tracker |
| `docs/` | Deployment, hardware and troubleshooting guides |
| `project/`, `chats/` | The original Claude Design handoff this was built from |

## Quick start

```bash
# 1. Backend
npm install
npx convex dev            # creates the deployment and generates convex/_generated
npx convex run seed:run   # seeds the six routes and their stops

# 2. App
cd app
flutter pub get
flutter run --dart-define=CONVEX_SITE_URL=https://<deployment>.convex.site
```

`npx convex dev` prints both a `.convex.cloud` and a `.convex.site` URL. The
app and the trackers use the **`.convex.site`** one — that is where HTTP
Actions are served.

For repeatable builds put the values in a file instead:

```bash
cp env/example.json env/prod.json    # then edit it
flutter run --dart-define-from-file=env/prod.json
```

## Building

```bash
# Android
flutter build apk --release --dart-define-from-file=env/prod.json
flutter build appbundle --release --dart-define-from-file=env/prod.json

# iOS (needs macOS + Xcode)
flutter build ipa --release --dart-define-from-file=env/prod.json

# Web
flutter build web --release --dart-define-from-file=env/prod.json
```

See [docs/deployment.md](docs/deployment.md) for signing, Google Sign-In setup
and the CORS origin, and [docs/android-setup.md](docs/android-setup.md) if
`flutter doctor` reports an Android toolchain problem.

## How it works

**Trackers are authoritative.** Each ESP32 posts to `/api/ingest` with a
per-device bearer token that is scoped to one route, so a leaked token can
only move the bus it was issued for. Fixes are snapped to the route polyline;
anything more than 450 m off it is stored but not used to move the bus.

**Riders fill the gaps.** When a bus's onboard unit goes quiet, riders on that
bus can opt into sharing their phone's location. Those fixes are only applied
while the device feed is stale, so a rider who stays on the bus after the
tracker recovers cannot fight it. Sharing is foreground-only and stops when
the app is backgrounded.

**ETAs come from geometry, not guesses.** Position is projected onto the route
to get progress and the next stop; distance remaining plus current speed gives
the ETA; comparing that against the stop's scheduled time gives the delay.
A bus stopped at a stop reports ~0 km/h, so a nominal cruise speed is used
instead of producing an infinite ETA.

**Signal quality is derived, not reported.** A fix older than 90 s is
`offline`; one that is rider-sourced, low-accuracy, or middle-aged is `weak`.
That single value drives the status pill, the map marker's opacity and the
banner copy.

## Status

Built and verified here: the Convex backend typechecks, and the Flutter app
passes `flutter analyze`, 13 tests including golden captures of every screen
in light and dark, and a release web build.

Not verified here, because this environment cannot reach `dl.google.com` or
`dl.espressif.com`: the Android/iOS binaries and the ESP32 firmware have not
been compiled. Build them locally with the commands above —
[docs/android-setup.md](docs/android-setup.md) covers the toolchain, and
[firmware/README.md](firmware/README.md) the tracker.
