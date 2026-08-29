# Fixing the Android toolchain

`flutter doctor` reporting a problem under **Android toolchain** almost always
means one of four things. Run it verbosely first — it names the exact cause:

```bash
flutter doctor -v
```

## "Unable to locate Android SDK"

Flutter cannot find an SDK. Install one, then point Flutter at it.

**With Android Studio (easiest).** Install Android Studio, open it, and let
the first-run wizard install the SDK. Then:

```bash
flutter config --android-sdk "$HOME/AppData/Local/Android/sdk"      # Windows
flutter config --android-sdk "$HOME/Library/Android/sdk"            # macOS
flutter config --android-sdk "$HOME/Android/Sdk"                    # Linux
```

**Without Android Studio.** Download the command-line tools from
<https://developer.android.com/studio#command-line-tools-only>, unzip so the
layout is `<sdk>/cmdline-tools/latest/bin`, then:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"

sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;27.0.12077973"
flutter config --android-sdk "$ANDROID_HOME"
```

On Windows PowerShell the equivalent is:

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:Path += ";$env:ANDROID_HOME\cmdline-tools\latest\bin;$env:ANDROID_HOME\platform-tools"
```

Set those permanently in your shell profile or Windows environment variables,
or every new terminal will forget them.

## "Android licenses not accepted"

```bash
flutter doctor --android-licenses
```

Accept each one. This needs a JDK on `PATH` — see the next section if it
fails immediately.

## "Unable to find bundled Java" / `JAVA_HOME` problems

Gradle needs JDK 17 or newer. Android Studio ships one:

```bash
# macOS
flutter config --jdk-dir "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
# Windows
flutter config --jdk-dir "C:\Program Files\Android\Android Studio\jbr"
# Linux
flutter config --jdk-dir "/opt/android-studio/jbr"
```

Otherwise install Temurin 17+ and set `JAVA_HOME` to it. Java 8 and 11 will
not build this project — `build.gradle.kts` targets Java 17.

## "cmdline-tools component is missing"

```bash
sdkmanager --install "cmdline-tools;latest"
```

## NDK version mismatch

If the build fails with `NDK not configured` or names a different NDK version
than the one it found, install the version this project pins:

```bash
sdkmanager --install "ndk;27.0.12077973"
```

`app/android/app/build.gradle.kts` pins this deliberately. Several plugins
(`geolocator`, `flutter_secure_storage`) request a specific NDK, and inheriting
`flutter.ndkVersion` produces a mismatch whose error message does not say so.

## Verify

```bash
flutter doctor -v          # Android toolchain should be ✓
flutter devices            # your phone or emulator should be listed
```

## Building the APK

```bash
cd app
flutter pub get
flutter build apk --release --dart-define-from-file=../env/prod.json
```

The APK lands at `app/build/app/outputs/flutter-apk/app-release.apk`.

To install it on a connected phone:

```bash
flutter install --release
# or
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

**Smaller downloads.** A universal APK carries every ABI. For side-loading,
split per architecture instead:

```bash
flutter build apk --release --split-per-abi --dart-define-from-file=../env/prod.json
```

Most phones want `app-arm64-v8a-release.apk`.

**For the Play Store,** build an App Bundle rather than an APK, and set up
release signing first — see [deployment.md](deployment.md):

```bash
flutter build appbundle --release --dart-define-from-file=../env/prod.json
```

## If the build still fails

```bash
flutter clean
cd android && ./gradlew clean && cd ..
flutter pub get
flutter build apk --release --dart-define-from-file=../env/prod.json -v
```

A first release build downloads a lot of Gradle dependencies and can take
several minutes — it is not hung.

Two failures that look like toolchain problems but are not:

- **A blank screen saying "Backend not configured"** — the APK built fine, but
  `CONVEX_SITE_URL` was not passed. Rebuild with `--dart-define-from-file`.
- **`Execution failed for task ':app:checkReleaseAarMetadata'`** — a plugin
  needs a higher `compileSdk`. Install the newer platform with
  `sdkmanager "platforms;android-36"`.
