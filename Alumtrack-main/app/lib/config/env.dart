/// Build-time configuration.
///
/// Supplied with `--dart-define`, so no deployment URL or client id is baked
/// into the repository:
///
///   flutter run --dart-define=API_BASE_URL=https://alumtrack.<sub>.workers.dev \
///               --dart-define=GOOGLE_WEB_CLIENT_ID=...apps.googleusercontent.com
///
/// For repeatable builds put them in a JSON file and pass
/// `--dart-define-from-file=env/prod.json` instead.
class Env {
  const Env._();

  /// Backend origin.
  ///
  /// `CONVEX_SITE_URL` is still read as a fallback: the backend moved from
  /// Convex to Cloudflare Workers, and silently ignoring the old key would
  /// break any build script or CI job still passing it — with the confusing
  /// symptom of a "not configured" screen rather than an error naming the
  /// variable. New builds should set `API_BASE_URL`.
  static const String _apiBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const String _legacyConvexUrl = String.fromEnvironment('CONVEX_SITE_URL');

  static String get apiBaseUrl =>
      _apiBaseUrl.isNotEmpty ? _apiBaseUrl : _legacyConvexUrl;

  /// OAuth client id used to obtain a Google ID token. On Android the native
  /// client is selected by package name + signing certificate, but the
  /// *server* client id must still be passed so the ID token's audience
  /// matches what the backend verifies against.
  static const String googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// Web builds need the web OAuth client id explicitly.
  static const String googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  static bool get hasBackend => apiBaseUrl.isNotEmpty;
  static bool get hasGoogleSignIn =>
      googleServerClientId.isNotEmpty || googleWebClientId.isNotEmpty;

  /// Human-readable reason the app cannot start, or null when configured.
  static String? get misconfiguration {
    final url = apiBaseUrl;
    if (url.isEmpty) {
      return 'API_BASE_URL was not set at build time.';
    }
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      return 'API_BASE_URL must be a full URL, got "$url".';
    }
    return null;
  }
}
