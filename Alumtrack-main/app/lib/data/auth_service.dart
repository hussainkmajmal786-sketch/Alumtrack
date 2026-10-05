import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/env.dart';
import 'api_client.dart';

/// Signed-in identity as the app knows it.
class Session {
  final String token;
  final String subject;
  final bool isGuest;

  const Session({
    required this.token,
    required this.subject,
    required this.isGuest,
  });
}

/// Issues, persists and revokes sessions.
///
/// Tokens go in the platform keystore/keychain where available. On web there
/// is no such store, so they fall back to `shared_preferences` (localStorage) —
/// acceptable because the token is scoped to this app's origin and expires,
/// but it is why the web build should be served from its own origin.
class AuthService {
  AuthService(this._api);

  final ApiClient _api;

  static const _tokenKey = 'alumtrack.session.token';
  static const _subjectKey = 'alumtrack.session.subject';
  static const _guestKey = 'alumtrack.session.guest';

  // The v11 defaults are already AES-GCM with RSA-OAEP key wrapping backed by
  // the Android keystore, so no options override is needed.
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  bool get _useSecureStorage => !kIsWeb;

  Future<void> _write(String key, String value) async {
    if (_useSecureStorage) {
      await _secure.write(key: key, value: value);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  Future<String?> _read(String key) async {
    if (_useSecureStorage) return _secure.read(key: key);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> _delete(String key) async {
    if (_useSecureStorage) {
      await _secure.delete(key: key);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    }
  }

  /// Reloads a stored session on launch, or null when there is none.
  Future<Session?> restore() async {
    final token = await _read(_tokenKey);
    final subject = await _read(_subjectKey);
    if (token == null || subject == null) return null;

    final session = Session(
      token: token,
      subject: subject,
      isGuest: (await _read(_guestKey)) == 'true',
    );
    _api.token = token;
    return session;
  }

  Future<void> _persist(Session session) async {
    await _write(_tokenKey, session.token);
    await _write(_subjectKey, session.subject);
    await _write(_guestKey, session.isGuest.toString());
    _api.token = session.token;
  }

  /// Exchanges a Google ID token for an app session.
  Future<Session> signInWithGoogle() async {
    if (!Env.hasGoogleSignIn) {
      throw const ApiException(
        'Google sign-in is not configured for this build.',
      );
    }

    final signIn = GoogleSignIn.instance;
    await signIn.initialize(
      clientId: kIsWeb
          ? (Env.googleWebClientId.isEmpty ? null : Env.googleWebClientId)
          : null,
      serverClientId:
          Env.googleServerClientId.isEmpty ? null : Env.googleServerClientId,
    );

    final account = await signIn.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const ApiException('Google did not return an ID token.');
    }

    final res = await _api.post('/api/auth/google', {'idToken': idToken});
    final session = Session(
      token: res['token'] as String,
      subject: res['subject'] as String,
      isGuest: false,
    );
    await _persist(session);
    return session;
  }

  /// Anonymous session, so guests still get a stable identity for their
  /// linked bus and rider sharing.
  Future<Session> continueAsGuest() async {
    final res = await _api.post('/api/auth/guest');
    final session = Session(
      token: res['token'] as String,
      subject: res['subject'] as String,
      isGuest: true,
    );
    await _persist(session);
    return session;
  }

  /// Creates a student account with email + password, as an alternative to
  /// Google Sign-In.
  Future<Session> signUpWithEmail({
    required String email,
    required String password,
    String? name,
  }) async {
    final res = await _api.post('/api/auth/student-signup', {
      'email': email,
      'password': password,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    final session = Session(
      token: res['token'] as String,
      subject: res['subject'] as String,
      isGuest: false,
    );
    await _persist(session);
    return session;
  }

  /// Signs a student in with the email + password they signed up with.
  Future<Session> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final res = await _api.post('/api/auth/student-login', {
      'email': email,
      'password': password,
    });
    final session = Session(
      token: res['token'] as String,
      subject: res['subject'] as String,
      isGuest: false,
    );
    await _persist(session);
    return session;
  }

  Future<void> signOut() async {
    try {
      await _api.post('/api/auth/signout');
    } on ApiException {
      // The local session is cleared regardless: a user who taps Sign out
      // while offline must not stay signed in.
    }
    try {
      // On web, GoogleSignIn.instance.signOut() can hang indefinitely for a
      // session that never used Google Sign-In (e.g. a guest), because the
      // underlying Google Identity Services JS SDK has nothing to tear down
      // and never resolves its promise. A hard timeout guarantees the local
      // sign-out below always runs, so Back/Sign out never gets stuck.
      await GoogleSignIn.instance.signOut().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Not signed in through Google, timed out, or the plugin is unavailable.
    }

    await _delete(_tokenKey);
    await _delete(_subjectKey);
    await _delete(_guestKey);
    _api.token = null;
  }
}
