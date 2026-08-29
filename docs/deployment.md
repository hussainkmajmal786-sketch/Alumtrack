# Deployment

## 1. Convex backend

```bash
npm install
npx convex dev        # first run: creates the project, generates convex/_generated
```

Note both URLs it prints. The `.convex.site` one serves HTTP Actions and is
what the app and the trackers talk to.

Seed the routes and stops:

```bash
npx convex run seed:run
```

`seed:run` is idempotent — re-running refreshes stop geometry without
duplicating routes. Edit `convex/seed.ts` to change stops or timetables.

### Environment variables

Set these in the Convex dashboard (Settings → Environment Variables):

| Variable | Required | Purpose |
| --- | --- | --- |
| `ADMIN_KEY` | yes | Bearer token for `/api/admin/devices`. Generate with `openssl rand -hex 32`. |
| `GOOGLE_CLIENT_IDS` | for Google sign-in | Comma-separated OAuth client ids whose ID tokens are accepted. |
| `ALLOWED_ORIGIN` | for web | Exact origin of the deployed web build, e.g. `https://alumtrack.example.edu`. Defaults to `*`. |
| `SCHEDULE_TZ_OFFSET_MINUTES` | no | Timezone for timetable comparisons. Defaults to `330` (IST). |

Leaving `ALLOWED_ORIGIN` unset is fine for development but means any site can
call the API with a user's token if they have one. Set it before going live.

Deploy to production:

```bash
npx convex deploy
```

### Getting route ids

Device provisioning and guest linking need a route id:

```bash
npx convex run routes:list '{}'
```

## 2. Google Sign-In

Create OAuth credentials at
<https://console.cloud.google.com/apis/credentials>. You need up to three
client ids, all listed in `GOOGLE_CLIENT_IDS`:

**Web application** — also add your web origin under *Authorized JavaScript
origins*. Pass it to the app as `GOOGLE_WEB_CLIENT_ID`.

**Android** — package name `com.campusbus.campus_bus_tracker` plus the SHA-1
of your signing certificate:

```bash
# debug
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey \
        -storepass android -keypass android | grep SHA1
# release
keytool -list -v -keystore <your>.jks -alias <alias> | grep SHA1
```

Register both, or Google sign-in will work in debug and fail in release.

**iOS** — bundle id `com.campusbus.campusBusTracker`.

The app passes the **web** client id as `GOOGLE_SERVER_CLIENT_ID` on mobile:
that is what sets the ID token's audience, and it must match one of the
`GOOGLE_CLIENT_IDS` the backend accepts.

Guest sign-in needs none of this and always works.

## 3. App configuration

```bash
cp env/example.json env/prod.json
```

```json
{
  "CONVEX_SITE_URL": "https://your-deployment.convex.site",
  "GOOGLE_SERVER_CLIENT_ID": "...apps.googleusercontent.com",
  "GOOGLE_WEB_CLIENT_ID": "...apps.googleusercontent.com"
}
```

`env/prod.json` is gitignored. Only `CONVEX_SITE_URL` is required — without
it the app shows a "Backend not configured" screen instead of failing at
every request.

## 4. Android release signing

Without this, release builds are signed with the debug key: fine for testing,
but they cannot be published or upgraded in place.

```bash
keytool -genkey -v -keystore ~/alumtrack.jks \
        -keyalg RSA -keysize 2048 -validity 10000 -alias alumtrack
```

Create `app/android/key.properties`:

```properties
storePassword=<password>
keyPassword=<password>
keyAlias=alumtrack
storeFile=/absolute/path/to/alumtrack.jks
```

Both that file and `*.jks` are gitignored. **Back the keystore up** — losing
it means you can never publish an update to the same app listing.

```bash
cd app
flutter build appbundle --release --dart-define-from-file=../env/prod.json
```

## 5. iOS

Needs macOS with Xcode. Set your team and bundle id in
`ios/Runner.xcodeproj`, then:

```bash
cd app
flutter build ipa --release --dart-define-from-file=../env/prod.json
```

The location permission string is already in `Info.plist`. The app requests
only "when in use" — do not add background location unless the product
actually changes, as App Review will ask you to justify it.

## 6. Web

```bash
cd app
flutter build web --release --dart-define-from-file=../env/prod.json
```

Serve `build/web` as static files. Two things to get right:

- Set `ALLOWED_ORIGIN` in Convex to this exact origin, or the browser blocks
  every API call with a CORS error.
- Serve it from its own origin. Session tokens fall back to `localStorage` on
  web because browsers have no keystore, so anything else on that origin can
  read them.

## 7. Provisioning trackers

One token per bus, scoped to one route:

```bash
curl -X POST https://<deployment>.convex.site/api/admin/devices \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"bus-12-a","routeId":"<route id>","label":"Route 12"}'
```

The response contains the plaintext token **once** — only its hash is stored.
Put it in `firmware/src/secrets.h`. Re-running the same call rotates the token.

To revoke a lost unit:

```bash
npx convex run devices:revoke '{"deviceId":"bus-12-a"}'
```

See [firmware/README.md](../firmware/README.md) for wiring and flashing.

## Operational notes

**Data retention.** Raw GPS fixes are pruned after 7 days by a cron. The
consolidated `liveState` row per route is what the app reads, so history is
only for debugging.

**Cost.** The app polls every 5 s on the live screen and 10 s on the list, and
only while it is in the foreground. Each tracker posts every 5 s while moving
and every 30 s when parked. Six buses running eight hours a day is on the
order of 40k ingest calls per day.

**Rider counts.** Shares are marked inactive after 90 s without a fix, swept
by a cron, because phones stop reporting without a clean sign-off.
