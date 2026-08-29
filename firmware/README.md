# Alumtrack bus tracker firmware

ESP32 + u-blox GPS unit that rides on the bus, joins the bus Wi-Fi, and posts
GPS fixes to the Convex ingest endpoint.

## Wiring

| NEO-6M / NEO-M8N | ESP32 devkit | Note |
| --- | --- | --- |
| `VCC` | `3V3` | The module draws ~50 mA; do not power it from a GPIO. |
| `GND` | `GND` | Common ground with the ESP32. |
| `TX`  | `GPIO16` (RX2) | GPS talks, ESP32 listens. |
| `RX`  | `GPIO17` (TX2) | Only needed to send u-blox config commands. |

The onboard LED (`GPIO2`) reports state at a glance:

| Pattern | Meaning |
| --- | --- |
| Solid | Wi-Fi connected and GPS has a fix — reporting normally. |
| Slow blink (1 s) | Wi-Fi up, still waiting for a usable GPS fix. |
| Fast blink (250 ms) | Wi-Fi down; fixes are being buffered. |

Give the antenna a clear view of the sky. Mounted inside a metal roof the
module will hold a fix poorly, which the backend will surface as "GPS signal
weak" rather than as a hard failure.

## Provisioning a tracker

Each unit needs its own identity and token. Register it against a route:

```bash
curl -X POST https://<your-deployment>.convex.site/api/admin/devices \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"bus-12-a","routeId":"<route id>","label":"Route 12 primary"}'
```

The response contains the plaintext `token` **once** — the backend only stores
its hash. Copy it straight into `secrets.h`; if you lose it, re-run the same
call to rotate.

Find the `routeId` with `npx convex run routes:list '{}'` after seeding.

## Build and flash

```bash
cp src/secrets.example.h src/secrets.h   # then fill it in
pio run                                  # build
pio run -t upload                        # flash over USB
pio device monitor                       # watch the log
```

`secrets.h` is gitignored, so each tracker's credentials stay out of the repo.

## Behaviour worth knowing

**Reporting cadence.** Every 5 s while moving, every 30 s when stopped. A fix
that has not moved 15 m from the last one is skipped unless the idle heartbeat
is due, so a bus waiting at a stop does not fill the buffer with GPS jitter.

**Offline buffering.** Fixes captured without Wi-Fi go into a 180-entry ring
buffer (~15 min of movement) and are flushed in batches of 40 on reconnect.
When it overflows, the oldest fixes are dropped: after a long outage the
freshest positions are the ones riders need.

**Clock.** Trackers have no RTC, so timestamps come from the GPS date, or from
the `serverTime` in the ingest response when there is no fix yet. Fixes sent
before either is known carry no timestamp and the server stamps them on
arrival.

**TLS.** Certificates are validated against the root bundle built into the
ESP32 core, so nothing needs pinning or rotating on the device.

**Failure backoff.** A rejected POST backs off (2 s doubling to 60 s) rather
than retrying every loop — otherwise a backend outage would block the loop on
the HTTP timeout and overflow the GPS serial buffer.

**Bad credentials.** A `401`/`403` drops the batch instead of queueing it
forever, and says so on the serial log. If you see that, the `DEVICE_ID` or
`DEVICE_TOKEN` in `secrets.h` does not match what the backend has.

## Toolchain notes

`platformio.ini` pins `espressif32@^6.9.0` (Arduino-ESP32 2.0.x). The code also
compiles against Arduino-ESP32 3.x — the certificate-bundle symbol and the
task-watchdog init API both changed there and are handled behind
`ESP_ARDUINO_VERSION_MAJOR` guards.
