/**
 * Alumtrack bus tracker.
 *
 * Reads a u-blox GPS over UART2, buffers fixes, and posts them to the Convex
 * ingest endpoint over the bus Wi-Fi. Everything in loop() is non-blocking
 * apart from the HTTP call itself, so GPS bytes are never dropped while the
 * radio is busy.
 */

#include <Arduino.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <TinyGPSPlus.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <esp_task_wdt.h>

#include "config.h"
#include "fix_buffer.h"
#include "secrets.h"

// Validates TLS against the Mozilla root store baked into the ESP32 core, so
// no certificate has to be pinned on the device or rotated when the backend's
// issuer changes. The symbol the core exports was renamed in Arduino-ESP32 3.x.
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
extern const uint8_t rootca_crt_bundle_start[] asm("_binary_x509_crt_bundle_start");
#else
extern const uint8_t rootca_crt_bundle_start[] asm("_binary_data_cert_x509_crt_bundle_start");
#endif

namespace {

TinyGPSPlus gps;
HardwareSerial gpsSerial(2);
FixBuffer buffer;

uint32_t lastSendAt = 0;
uint32_t lastWifiAttemptAt = 0;
uint32_t wifiRetryDelay = WIFI_RETRY_MIN_MS;
bool usingFallbackNetwork = false;

// A failing POST blocks for the full HTTP timeout. Retrying it every pass
// would starve the GPS UART, so failures back off before the next attempt.
uint32_t nextFlushAt = 0;
uint32_t flushRetryDelay = FLUSH_RETRY_MIN_MS;

double lastSentLat = 0;
double lastSentLng = 0;
bool hasSentAny = false;

/**
 * Offset from millis() to epoch millis, learned from the GPS date or the
 * server's response. Zero until we know the wall clock.
 */
uint64_t epochOffsetMs = 0;

uint64_t nowEpochMs() {
  return epochOffsetMs == 0 ? 0 : epochOffsetMs + millis();
}

void setEpochFromServer(uint64_t serverTimeMs) {
  if (serverTimeMs > 1600000000000ULL) {
    epochOffsetMs = serverTimeMs - millis();
  }
}

/**
 * Days since the Unix epoch for a civil date (Howard Hinnant's days_from_civil).
 *
 * Done by hand rather than via timegm()/mktime() so the result cannot depend
 * on the device's timezone state or on which libc the core happens to ship.
 */
int64_t daysFromCivil(int64_t y, unsigned m, unsigned d) {
  y -= m <= 2;
  const int64_t era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + static_cast<int64_t>(doe) - 719468;
}

/** Derives wall-clock time from the GPS date/time, which is always UTC. */
void setEpochFromGps() {
  if (!gps.date.isValid() || !gps.time.isValid() || gps.date.year() < 2023) return;

  const int64_t days = daysFromCivil(gps.date.year(), gps.date.month(), gps.date.day());
  const uint64_t epochMs =
      static_cast<uint64_t>(days * 86400LL + gps.time.hour() * 3600LL +
                           gps.time.minute() * 60LL + gps.time.second()) *
          1000ULL +
      gps.time.centisecond() * 10ULL;

  epochOffsetMs = epochMs - millis();
}

double metresBetween(double lat1, double lng1, double lat2, double lng2) {
  return TinyGPSPlus::distanceBetween(lat1, lng1, lat2, lng2);
}

void setLed(bool on) { digitalWrite(STATUS_LED_PIN, on ? HIGH : LOW); }

/**
 * Blinks a diagnostic pattern without blocking:
 *   solid  — connected and reporting
 *   slow   — Wi-Fi up, waiting for a GPS fix
 *   fast   — Wi-Fi down
 */
void updateLed(bool wifiUp, bool haveFix) {
  if (wifiUp && haveFix) {
    setLed(true);
    return;
  }
  const uint32_t period = wifiUp ? 1000 : 250;
  setLed((millis() % period) < (period / 2));
}

bool startWifi(bool useFallback) {
  const char *ssid = useFallback ? WIFI_SSID_FALLBACK : WIFI_SSID;
  const char *password = useFallback ? WIFI_PASSWORD_FALLBACK : WIFI_PASSWORD;
  if (strlen(ssid) == 0) return false;

  Serial.printf("[wifi] connecting to %s\n", ssid);
  WiFi.disconnect(true);
  WiFi.mode(WIFI_STA);
  // A tracker that sleeps its radio adds latency to every post for no real
  // saving on a bus that is already powering the unit.
  WiFi.setSleep(false);
  WiFi.begin(ssid, password);
  return true;
}

/** Non-blocking Wi-Fi supervision with exponential backoff. */
void serviceWifi() {
  if (WiFi.status() == WL_CONNECTED) {
    wifiRetryDelay = WIFI_RETRY_MIN_MS;
    return;
  }

  const uint32_t now = millis();
  if (now - lastWifiAttemptAt < wifiRetryDelay) return;
  lastWifiAttemptAt = now;

  // Alternate between the primary and fallback networks so a bus parked
  // outside the primary's range still finds a way home.
  if (strlen(WIFI_SSID_FALLBACK) > 0) usingFallbackNetwork = !usingFallbackNetwork;
  if (!startWifi(usingFallbackNetwork)) startWifi(false);

  wifiRetryDelay = min(wifiRetryDelay * 2, WIFI_RETRY_MAX_MS);
}

/** Serialises up to MAX_BATCH buffered fixes and posts them. */
bool flushBuffer() {
  if (buffer.empty() || WiFi.status() != WL_CONNECTED) return false;

  static Fix batch[MAX_BATCH];
  const size_t count = buffer.peek(batch, MAX_BATCH);
  if (count == 0) return false;

  JsonDocument doc;
  doc["deviceId"] = DEVICE_ID;
  doc["firmware"] = FIRMWARE_VERSION;
  doc["rssi"] = WiFi.RSSI();

  JsonArray arr = doc["batch"].to<JsonArray>();
  for (size_t i = 0; i < count; i++) {
    JsonObject o = arr.add<JsonObject>();
    o["lat"] = batch[i].lat;
    o["lng"] = batch[i].lng;
    o["speedKph"] = batch[i].speedKph;
    o["headingDeg"] = batch[i].headingDeg;
    o["hdop"] = batch[i].hdop;
    o["satellites"] = batch[i].satellites;
    if (batch[i].recordedAt > 0) o["recordedAt"] = batch[i].recordedAt;
  }

  String body;
  serializeJson(doc, body);

  WiFiClientSecure client;
  client.setCACertBundle(rootca_crt_bundle_start);
  client.setTimeout(HTTP_TIMEOUT_MS / 1000);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(client, INGEST_URL)) {
    Serial.println("[http] begin failed");
    return false;
  }
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Authorization", String("Bearer ") + DEVICE_TOKEN);

  const int status = http.POST(body);

  if (status == 200) {
    // Read the server clock before releasing the connection so buffered
    // fixes get real timestamps even without a GPS date.
    JsonDocument response;
    if (deserializeJson(response, http.getString()) == DeserializationError::Ok) {
      setEpochFromServer(response["serverTime"].as<uint64_t>());
    }
    buffer.consume(count);
    flushRetryDelay = FLUSH_RETRY_MIN_MS;
    Serial.printf("[http] sent %u fix(es), %u queued\n", (unsigned)count,
                  (unsigned)buffer.size());
    http.end();
    return true;
  }

  // 401/403 means the token is wrong or revoked. Retrying cannot fix that,
  // and the queue would grow forever, so drop the batch and keep running.
  if (status == 401 || status == 403) {
    Serial.printf("[http] rejected (%d) — check DEVICE_ID / DEVICE_TOKEN\n", status);
    buffer.consume(count);
  } else {
    Serial.printf("[http] failed (%d), keeping %u queued\n", status,
                  (unsigned)buffer.size());
  }

  nextFlushAt = millis() + flushRetryDelay;
  flushRetryDelay = min(flushRetryDelay * 2, FLUSH_RETRY_MAX_MS);

  http.end();
  return false;
}

bool haveUsableFix() {
  return gps.location.isValid() && gps.location.age() < 5000 &&
         gps.satellites.isValid() && gps.satellites.value() >= MIN_SATELLITES;
}

/** Decides whether this fix is worth queueing yet. */
bool shouldCapture() {
  const double speed = gps.speed.isValid() ? gps.speed.kmph() : 0.0;
  const bool moving = speed >= MOVING_SPEED_KPH;
  const uint32_t interval = moving ? SEND_INTERVAL_MOVING_MS : SEND_INTERVAL_IDLE_MS;

  const uint32_t elapsed = millis() - lastSendAt;
  if (elapsed < interval) return false;

  // Always let the idle heartbeat through; otherwise require real movement
  // so GPS jitter at a stop does not fill the buffer.
  if (moving && hasSentAny) {
    const double moved = metresBetween(lastSentLat, lastSentLng,
                                       gps.location.lat(), gps.location.lng());
    if (moved < MIN_MOVE_METRES && elapsed < SEND_INTERVAL_IDLE_MS) return false;
  }

  return true;
}

void captureFix() {
  Fix fix;
  fix.lat = gps.location.lat();
  fix.lng = gps.location.lng();
  fix.speedKph = gps.speed.isValid() ? gps.speed.kmph() : 0.0f;
  fix.headingDeg = gps.course.isValid() ? gps.course.deg() : 0.0f;
  fix.hdop = gps.hdop.isValid() ? gps.hdop.hdop() : 99.0f;
  fix.satellites = gps.satellites.isValid() ? gps.satellites.value() : 0;
  fix.recordedAt = nowEpochMs();

  buffer.push(fix);

  lastSentLat = fix.lat;
  lastSentLng = fix.lng;
  hasSentAny = true;
  lastSendAt = millis();

  Serial.printf("[gps] %.6f,%.6f  %.1f km/h  hdop %.1f  sats %u  queued %u\n",
                fix.lat, fix.lng, fix.speedKph, fix.hdop, fix.satellites,
                (unsigned)buffer.size());
}

}  // namespace

void setup() {
  Serial.begin(115200);
  pinMode(STATUS_LED_PIN, OUTPUT);
  setLed(false);

  gpsSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);

  Serial.printf("\n[boot] Alumtrack tracker %s  device=%s\n", FIRMWARE_VERSION, DEVICE_ID);

  // The watchdog config API changed shape in ESP-IDF 5 (Arduino-ESP32 3.x).
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  esp_task_wdt_config_t wdtConfig = {
      .timeout_ms = WATCHDOG_TIMEOUT_S * 1000,
      .idle_core_mask = 0,
      .trigger_panic = true,
  };
  esp_task_wdt_reconfigure(&wdtConfig);
#else
  esp_task_wdt_init(WATCHDOG_TIMEOUT_S, true);
#endif
  esp_task_wdt_add(nullptr);

  startWifi(false);
}

void loop() {
  esp_task_wdt_reset();

  // Drain the UART every pass. TinyGPS++ needs a steady byte stream, and
  // starving it here shows up as stale fixes rather than an obvious error.
  while (gpsSerial.available() > 0) {
    gps.encode(gpsSerial.read());
  }

  serviceWifi();

  if (epochOffsetMs == 0) setEpochFromGps();

  const bool fixOk = haveUsableFix();
  if (fixOk && shouldCapture()) captureFix();

  // flushBuffer() is the only blocking call in the loop, so it runs only
  // when there is something to send and any failure backoff has elapsed.
  if (!buffer.empty() && static_cast<int32_t>(millis() - nextFlushAt) >= 0) {
    flushBuffer();
  }

  updateLed(WiFi.status() == WL_CONNECTED, fixOk);
}
