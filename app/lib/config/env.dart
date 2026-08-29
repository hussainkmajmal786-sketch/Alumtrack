/// Build-time configuration.
///
/// Supplied with `--dart-define`, so no deployment URL or client id is baked
/// into the repository:
///
///   flutter run --dart-define=CONVEX_SITE_URL=https://x.convex.site \
///               --dart-define=GOOGLE_WEB_CLIENT_ID=...apps.googleusercontent.com
///
/// For repeatable builds put them in a JSON file and pass
/// `--dart-define-from-file=env/prod.json` instead.
class Env {
  const Env._();

  /// Convex HTTP Actions origin. This is the `.convex.site` host — the
  /// `.convex.cloud` one serves the client sync protocol, not these routes.
  static const String convexSiteUrl = String.fromEnvironment('CONVEX_SITE_URL');

  /// OAuth client id used to obtain a Google ID token. On Android the native
  /// client is selected by package name + signing certificate, but the
  /// *server* client id must still be passed so the ID token's audience
  /// matches what the backend verifies against.
  static const String googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// Web builds need the web OAuth client id explicitly.
  static const String googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  static bool get hasBackend => convexSiteUrl.isNotEmpty;
  static bool get hasGoogleSignIn =>
      googleServerClientId.isNotEmpty || googleWebClientId.isNotEmpty;

  /// Human-readable reason the app cannot start, or null when configured.
  static String? get misconfiguration {
    if (convexSiteUrl.isEmpty) {
      return 'CONVEX_SITE_URL was not set at build time.';
    }
    if (!convexSiteUrl.startsWith('https://') &&
        !convexSiteUrl.startsWith('http://')) {
      return 'CONVEX_SITE_URL must be a full URL, got "$convexSiteUrl".';
    }
    return null;
  }
}
