import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_client.dart';
import '../data/admin_service.dart';
import '../data/bus_sounds.dart';
import '../data/auth_service.dart';
import '../data/bus_repository.dart';
import '../data/location_service.dart';
import '../models/bus.dart';
import '../models/stop.dart';

enum AppScreen {
  landing,
  auth,
  list,
  bus,
  settings,
  adminAuth,
  adminDashboard,
  studentEmailAuth,
}

enum ThemeSetting { system, light, dark }

/// Loading lifecycle for a piece of remote data.
enum Loadable { idle, loading, ready, failed }

/// How often live data is refetched while its screen is visible.
///
/// Deliberately no faster than the tracker itself reports. The ESP32 posts
/// every 5s while moving and every 30s at rest (SEND_INTERVAL_MOVING_MS /
/// SEND_INTERVAL_IDLE_MS in the firmware), so polling at 5s spent roughly
/// half its requests re-fetching a position that had not changed — about
/// 500k wasted backend calls a month per active viewer, which is what tipped
/// this deployment past its plan limit.
///
/// 12s still feels live for a vehicle at road speed (~100m between updates)
/// while cutting the call volume by well over half. The bus marker animates
/// between fixes anyway, so the motion on screen stays smooth regardless.
const _listPollInterval = Duration(seconds: 30);
const _detailPollInterval = Duration(seconds: 12);

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    required ApiClient api,
    required AuthService auth,
    required BusRepository repository,
    LocationService? location,
    // ignore: prefer_initializing_formals
  })  : _api = api,
        // ignore: prefer_initializing_formals
        _auth = auth,
        _repo = repository,
        _location = location ?? LocationService() {
    WidgetsBinding.instance.addObserver(this);
    systemDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
  }

  final ApiClient _api;
  final AuthService _auth;
  final BusRepository _repo;
  final LocationService _location;

  // --- Session ---------------------------------------------------------
  Session? session;
  Profile? profile;
  bool bootstrapping = true;

  bool get authed => session != null && session!.isGuest == false;
  bool get isGuest => session?.isGuest ?? true;

  // --- Staff (admin/superadmin) session --------------------------------
  final AdminService adminApi = AdminService();
  AdminSession? adminSession;
  bool adminSigningIn = false;
  String? adminAuthError;

  // --- Navigation ------------------------------------------------------
  AppScreen screen = AppScreen.landing;
  AppScreen? cameFrom;

  // --- Appearance ------------------------------------------------------
  ThemeSetting themeSetting = ThemeSetting.system;
  late bool systemDark;

  // --- Buses list ------------------------------------------------------
  Loadable listState = Loadable.idle;
  String? listError;
  bool listErrorRetryable = false;
  List<Bus> buses = const [];
  String query = '';
  DateTime? listUpdatedAt;
  Timer? _listTimer;

  /// Most-recently-opened route ids, newest first, capped at 3 — a small
  /// "Recent" shelf above the full list, the way Maps surfaces recent
  /// searches. Persisted locally (not per-account) since it is a device
  /// convenience, not data anyone else needs to see.
  static const int _maxRecentRoutes = 3;
  static const _recentRoutesKey = 'alumtrack.recentRouteIds';
  static const _busSoundsKey = 'alumtrack.busSoundsEnabled';

  // --- Bus movement sounds ----------------------------------------------
  final BusSounds _sounds = BusSounds();

  /// Off by default: audio that starts playing unasked is intrusive, and
  /// a rider who wants it can turn it on in Settings once.
  bool busSoundsEnabled = false;

  /// Whether the bus was moving as of the previous fix, so only the
  /// transition (stopped -> moving, moving -> stopped) plays a cue rather
  /// than every update while it drives.
  bool? _busWasMoving;

  /// Below this the vehicle is treated as stopped. Matches the firmware's
  /// own MOVING_SPEED_KPH so the app and the tracker agree on what
  /// "moving" means rather than drifting apart.
  static const double _movingSpeedKph = 4.0;
  List<String> recentRouteIds = [];

  /// The subset of [buses] referenced by [recentRouteIds], in that same
  /// recency order — filters out ids for routes that no longer exist or
  /// are not in the currently visible list.
  List<Bus> get recentBuses {
    final byId = {for (final b in buses) b.id: b};
    return recentRouteIds.map((id) => byId[id]).whereType<Bus>().toList();
  }

  // --- Route detail ----------------------------------------------------
  Loadable detailState = Loadable.idle;
  String? detailError;
  bool detailErrorRetryable = false;
  RouteDetail? detail;
  String? activeRouteId;
  Timer? _detailTimer;

  // --- Alerts ----------------------------------------------------------
  AlertFeed? alerts;
  Loadable alertsState = Loadable.idle;
  bool notifOpen = false;
  int get badge => alerts?.unread ?? 0;

  // --- Rider sharing ---------------------------------------------------
  bool collabOpen = false;
  bool sharing = false;
  String? sharingError;
  bool sharingErrorNeedsSettings = false;

  // --- Trip feedback -----------------------------------------------------
  bool feedbackOpen = false;
  bool feedbackSubmitting = false;
  String? feedbackError;

  /// The trip currently being (or about to be) rated — set the moment a
  /// journey completes, so the prompt keeps referring to that trip even if
  /// polling moves `detail` on while the modal is open.
  String? _feedbackRouteId;
  int? _feedbackTripEndedAt;

  /// `routeId@tripEndedAt` keys already prompted this session, so a
  /// dismissed prompt does not reappear on the very next poll for the same
  /// trip. Not persisted — a fresh app launch may prompt again for a trip
  /// that technically already ended, which is an acceptable trade for not
  /// needing a server round-trip just to check "did I already see this".
  final Set<String> _promptedTrips = {};

  // --- Settings --------------------------------------------------------
  String lead = '5 min';

  bool get isDark {
    switch (themeSetting) {
      case ThemeSetting.dark:
        return true;
      case ThemeSetting.light:
        return false;
      case ThemeSetting.system:
        return systemDark;
    }
  }

  String get settingsBackLabel =>
      cameFrom == AppScreen.bus ? 'Route ${detail?.number ?? ''}'.trim() : 'Buses';

  String get appearanceNote {
    switch (themeSetting) {
      case ThemeSetting.system:
        return 'Following your device appearance — currently '
            '${systemDark ? 'Dark' : 'Light'}.';
      case ThemeSetting.light:
        return 'Always Light, regardless of system setting.';
      case ThemeSetting.dark:
        return 'Always Dark, regardless of system setting.';
    }
  }

  int get riders => detail?.riders ?? 0;

  String get ridersLabel =>
      '$riders ${riders == 1 ? 'rider sharing' : 'riders sharing'}';

  /// Relative "Updated ..." text for the list header.
  String get updated {
    final at = listUpdatedAt;
    if (at == null) return 'never';
    final seconds = DateTime.now().difference(at).inSeconds;
    if (seconds < 45) return 'just now';
    final minutes = (seconds / 60).round();
    return minutes < 60 ? '$minutes min ago' : '${(minutes / 60).round()} h ago';
  }

  List<Bus> get visibleBuses =>
      buses.where((b) => b.matches(query.trim())).toList();

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Restores a stored session and routes to the right first screen.
  Future<void> bootstrap() async {
    unawaited(_loadRecentRoutes());
    unawaited(_loadBusSoundsPreference());
    try {
      final restored = await _auth.restore();
      if (restored != null) {
        session = restored;
        profile = await _repo.profile();
        _applyProfile();
        _goInitial();
      }
    } on ApiException catch (e) {
      // A rejected token means the session expired while the app was closed;
      // fall back to the auth screen rather than showing a broken shell.
      if (e.isUnauthorized) {
        await _auth.signOut();
        session = null;
      }
    } catch (_) {
      // Storage unavailable (e.g. a locked keystore). Start signed out.
    } finally {
      bootstrapping = false;
      notifyListeners();
    }
  }

  void _applyProfile() {
    final p = profile;
    if (p == null) return;
    lead = '${p.notifyLeadMinutes} min';
  }

  void _goInitial() {
    if (session == null) {
      // No prior session at all: a first-time (or fully signed-out) visitor
      // sees the landing page, not the sign-in options directly.
      screen = AppScreen.landing;
    } else if (session!.isGuest) {
      final linked = profile?.linkedRouteId;
      if (linked != null) {
        activeRouteId = linked;
        screen = AppScreen.bus;
        _startDetailPolling();
      } else {
        screen = AppScreen.auth;
      }
    } else {
      screen = AppScreen.list;
      _startListPolling();
    }
  }

  @override
  void didChangePlatformBrightness() {
    systemDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumePolling();
    } else {
      // Stop network and GPS work the moment the app leaves the foreground —
      // the consent copy promises sharing stops, and polling a hidden screen
      // just burns battery and data.
      _stopPolling();
      if (sharing) unawaited(_stopSharing(notifyServer: true));
    }
  }

  void _resumePolling() {
    switch (screen) {
      case AppScreen.list:
        _startListPolling();
        break;
      case AppScreen.bus:
        _startDetailPolling();
        break;
      default:
        break;
    }
  }

  void _stopPolling() {
    _listTimer?.cancel();
    _listTimer = null;
    _detailTimer?.cancel();
    _detailTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    unawaited(_location.stop());
    unawaited(_sounds.dispose());
    _api.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Auth actions
  // ---------------------------------------------------------------------

  bool signingIn = false;
  String? authError;

  Future<void> signInGoogle() async {
    signingIn = true;
    authError = null;
    notifyListeners();
    try {
      session = await _auth.signInWithGoogle();
      profile = await _repo.profile();
      _applyProfile();
      _go(AppScreen.list);
      await refreshList();
    } on ApiException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = 'Sign-in was cancelled.';
    } finally {
      signingIn = false;
      notifyListeners();
    }
  }

  Future<void> continueGuest() async {
    signingIn = true;
    authError = null;
    notifyListeners();
    try {
      session = await _auth.continueAsGuest();
      profile = await _repo.profile();
      _applyProfile();

      // A guest sees exactly one bus. Without a linked route there is nothing
      // to show, so link the first available route on their behalf.
      var routeId = profile?.linkedRouteId;
      if (routeId == null) {
        final all = await _repo.routes();
        if (all.isNotEmpty) {
          profile = await _repo.updatePreferences(linkedRouteId: all.first.id);
          routeId = profile?.linkedRouteId;
        }
      }

      if (routeId == null) {
        authError = 'No routes are available yet.';
        return;
      }

      activeRouteId = routeId;
      _go(AppScreen.bus);
      await refreshDetail();
    } on ApiException catch (e) {
      authError = e.message;
    } finally {
      signingIn = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Student email + password (alternative to Google Sign-In)
  // ---------------------------------------------------------------------

  bool studentEmailSigningIn = false;
  String? studentEmailAuthError;
  bool studentEmailSignUpMode = true;

  void goStudentEmailAuth() {
    studentEmailAuthError = null;
    studentEmailSignUpMode = true;
    _go(AppScreen.studentEmailAuth);
  }

  void studentEmailBackToAuth() {
    studentEmailAuthError = null;
    _go(AppScreen.auth);
  }

  void toggleStudentEmailMode() {
    studentEmailAuthError = null;
    studentEmailSignUpMode = !studentEmailSignUpMode;
    notifyListeners();
  }

  Future<void> _afterStudentEmailAuth() async {
    profile = await _repo.profile();
    _applyProfile();

    var routeId = profile?.linkedRouteId;
    if (routeId == null) {
      final all = await _repo.routes();
      if (all.isNotEmpty) {
        profile = await _repo.updatePreferences(linkedRouteId: all.first.id);
        routeId = profile?.linkedRouteId;
      }
    }

    if (routeId == null) {
      _go(AppScreen.list);
      await refreshList();
      return;
    }

    activeRouteId = routeId;
    _go(AppScreen.bus);
    await refreshDetail();
  }

  Future<void> studentSignUp({
    required String name,
    required String email,
    required String password,
  }) async {
    studentEmailSigningIn = true;
    studentEmailAuthError = null;
    notifyListeners();
    try {
      session = await _auth.signUpWithEmail(name: name, email: email, password: password);
      await _afterStudentEmailAuth();
    } on ApiException catch (e) {
      studentEmailAuthError = e.message;
    } finally {
      studentEmailSigningIn = false;
      notifyListeners();
    }
  }

  Future<void> studentSignIn({
    required String email,
    required String password,
  }) async {
    studentEmailSigningIn = true;
    studentEmailAuthError = null;
    notifyListeners();
    try {
      session = await _auth.signInWithEmail(email: email, password: password);
      await _afterStudentEmailAuth();
    } on ApiException catch (e) {
      studentEmailAuthError = e.message;
    } finally {
      studentEmailSigningIn = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Staff (admin/superadmin) actions
  // ---------------------------------------------------------------------

  void adminBackToAuth() {
    adminAuthError = null;
    // The only way in is the landing page's hidden gesture, so that is the
    // one coherent place to land on the way back out — regardless of
    // whether a student-facing auth screen was ever visited this session.
    _go(AppScreen.landing);
  }

  Future<void> adminSignIn(String email, String password) async {
    adminSigningIn = true;
    adminAuthError = null;
    notifyListeners();
    try {
      adminSession = await adminApi.login(email, password);
      _go(AppScreen.adminDashboard);
    } on ApiException catch (e) {
      adminAuthError = e.message;
    } catch (_) {
      adminAuthError = 'Sign-in failed.';
    } finally {
      adminSigningIn = false;
      notifyListeners();
    }
  }

  Future<void> adminSignOut() async {
    await adminApi.signOut();
    adminSession = null;
    _go(AppScreen.auth);
  }

  Future<void> signOut() async {
    _stopPolling();
    await _stopSharing(notifyServer: true);
    await _auth.signOut();
    session = null;
    profile = null;
    buses = const [];
    detail = null;
    alerts = null;
    activeRouteId = null;
    listState = Loadable.idle;
    detailState = Loadable.idle;
    _go(AppScreen.auth);
  }

  /// Clears local session state after the backend rejected our token.
  Future<void> _handleUnauthorized() async {
    await _auth.signOut();
    session = null;
    profile = null;
    _stopPolling();
    _go(AppScreen.auth);
  }

  // ---------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------

  void _go(AppScreen next) {
    notifOpen = false;
    collabOpen = false;
    screen = next;

    _stopPolling();
    if (next == AppScreen.list) {
      _startListPolling();
    } else if (next == AppScreen.bus) {
      _startDetailPolling();
    }
    notifyListeners();
  }

  void goAuth() => unawaited(signOut());

  /// From the landing page only: there is no session to sign out of yet, so
  /// this is a plain transition rather than [goAuth]'s sign-out-then-auth.
  void goAuthFromLanding() => _go(AppScreen.auth);

  /// Back-navigation counterpart to [goAuthFromLanding] — pressing back on
  /// the auth screen returns to the landing page rather than exiting, since
  /// landing (not auth) is now the app's actual root screen.
  void goToLandingFromAuth() => _go(AppScreen.landing);

  /// The landing page's hidden entry point into admin sign-in — reachable by
  /// a long-press gesture on the wordmark rather than a visible link, so
  /// students are never shown an "Admin sign in" option.
  void goAdminAuthFromLanding() {
    adminAuthError = null;
    _go(AppScreen.adminAuth);
  }

  void goList() {
    if (isGuest) return;
    _go(AppScreen.list);
    unawaited(refreshList());
  }

  void openBus(String routeId) {
    activeRouteId = routeId;
    detail = null;
    detailState = Loadable.loading;
    _go(AppScreen.bus);
    unawaited(refreshDetail());
    unawaited(_recordRecentRoute(routeId));
  }

  Future<void> _loadRecentRoutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      recentRouteIds = prefs.getStringList(_recentRoutesKey) ?? [];
      notifyListeners();
    } catch (_) {
      // Storage unavailable — recents just stay empty for this session.
    }
  }

  Future<void> _recordRecentRoute(String routeId) async {
    recentRouteIds = [
      routeId,
      ...recentRouteIds.where((id) => id != routeId),
    ].take(_maxRecentRoutes).toList();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentRoutesKey, recentRouteIds);
    } catch (_) {
      // Best-effort persistence; an in-memory recents shelf for the rest of
      // this session is still better than failing the whole navigation.
    }
  }

  void goBus() {
    final id = activeRouteId ?? profile?.linkedRouteId;
    if (id == null) return;
    openBus(id);
  }

  void goSettings() {
    cameFrom = screen;
    _go(AppScreen.settings);
  }

  void backFromBus() => isGuest ? goAuth() : goList();

  void backFromSettings() {
    if (cameFrom == AppScreen.bus) {
      _go(AppScreen.bus);
      unawaited(refreshDetail());
    } else {
      goList();
    }
  }

  // ---------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------

  void _startListPolling() {
    _listTimer?.cancel();
    _listTimer = Timer.periodic(_listPollInterval, (_) => refreshList(quiet: true));
    unawaited(refreshList());
  }

  void _startDetailPolling() {
    _detailTimer?.cancel();
    _detailTimer =
        Timer.periodic(_detailPollInterval, (_) => refreshDetail(quiet: true));
    unawaited(refreshDetail());
  }

  /// [quiet] refreshes in the background without flipping the screen back to
  /// a spinner — a poll that fails should not blank out good data on screen.
  Future<void> refreshList({bool quiet = false}) async {
    if (session == null) return;
    if (!quiet) {
      listState = Loadable.loading;
      listError = null;
      notifyListeners();
    }
    try {
      buses = await _repo.routes();
      listUpdatedAt = DateTime.now();
      listState = Loadable.ready;
      listError = null;
      unawaited(refreshAlerts());
    } on ApiException catch (e) {
      if (e.isUnauthorized) return _handleUnauthorized();
      if (!quiet || listState != Loadable.ready) {
        listState = Loadable.failed;
        listError = e.message;
        listErrorRetryable = e.retryable;
      }
    }
    notifyListeners();
  }

  Future<void> refreshDetail({bool quiet = false}) async {
    final id = activeRouteId;
    if (id == null || session == null) return;
    if (!quiet) {
      detailState = Loadable.loading;
      detailError = null;
      notifyListeners();
    }
    try {
      final next = await _repo.routeDetail(id);
      detail = next;
      sharing = next.sharing;
      detailState = Loadable.ready;
      detailError = null;
      _maybePromptFeedback(id, next);
      _maybePlayMovementSound(next);
      unawaited(refreshAlerts());
    } on ApiException catch (e) {
      if (e.isUnauthorized) return _handleUnauthorized();
      if (!quiet || detailState != Loadable.ready) {
        detailState = Loadable.failed;
        detailError = e.message;
        detailErrorRetryable = e.retryable;
      }
    }
    notifyListeners();
  }

  Future<void> refreshAlerts() async {
    if (session == null) return;
    try {
      alerts = await _repo.alerts();
      alertsState = Loadable.ready;
      notifyListeners();
    } on ApiException catch (e) {
      if (e.isUnauthorized) return _handleUnauthorized();
      // Alerts are secondary; a failure here should not disturb the screen.
      alertsState = Loadable.failed;
    }
  }

  Future<void> refresh() => screen == AppScreen.bus ? refreshDetail() : refreshList();

  // ---------------------------------------------------------------------
  // Preferences
  // ---------------------------------------------------------------------

  void setTheme(ThemeSetting t) {
    themeSetting = t;
    notifyListeners();
  }

  Future<void> setLead(String value) async {
    final previous = lead;
    lead = value;
    notifyListeners();
    try {
      final minutes = int.parse(value.split(' ').first);
      profile = await _repo.updatePreferences(notifyLeadMinutes: minutes);
    } on ApiException {
      lead = previous;
      notifyListeners();
    }
  }

  void setQuery(String value) {
    query = value;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Alerts panel
  // ---------------------------------------------------------------------

  // ---------------------------------------------------------------------
  // Bus movement sounds
  // ---------------------------------------------------------------------

  /// Plays a cue when the bus crosses between stopped and moving.
  ///
  /// Only the transition fires, never the steady state, so a bus driving
  /// for twenty minutes produces one sound at the start of that stretch
  /// rather than one per poll.
  void _maybePlayMovementSound(RouteDetail next) {
    final live = next.live;
    if (live == null || live.stale) {
      // A dropped feed is not the bus stopping — resetting to unknown
      // avoids a phantom "it stopped" cue when the signal simply died,
      // and a phantom "it started" when it comes back mid-journey.
      _busWasMoving = null;
      return;
    }

    final isMoving = (live.speedKph ?? 0) >= _movingSpeedKph;
    final was = _busWasMoving;
    _busWasMoving = isMoving;

    // The first fix after opening a route establishes the baseline; it is
    // not a transition, so it stays silent.
    if (was == null || was == isMoving) return;
    if (!busSoundsEnabled) return;

    unawaited(isMoving ? _sounds.playStart() : _sounds.playStop());
  }

  Future<void> setBusSoundsEnabled(bool value) async {
    busSoundsEnabled = value;
    notifyListeners();
    // Play the start cue as immediate confirmation of what was just turned
    // on — otherwise the rider has no idea what they enabled until the bus
    // happens to move.
    if (value) unawaited(_sounds.playStart());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_busSoundsKey, value);
    } catch (_) {
      // Preference is still applied for this session.
    }
  }

  Future<void> _loadBusSoundsPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      busSoundsEnabled = prefs.getBool(_busSoundsKey) ?? false;
      notifyListeners();
    } catch (_) {
      // Leave it off.
    }
  }

  void openNotif() {
    notifOpen = true;
    notifyListeners();
    unawaited(_markAlertsRead());
  }

  Future<void> _markAlertsRead() async {
    try {
      await _repo.markAlertsRead();
      await refreshAlerts();
    } on ApiException {
      // Leaving them unread is harmless; they clear on the next open.
    }
  }

  void closeNotif() {
    notifOpen = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Trip feedback
  // ---------------------------------------------------------------------

  /// Checks whether the just-fetched detail means this trip has ended, and
  /// opens the feedback prompt if so and it has not already been shown for
  /// this exact trip. Guests are skipped: feedback is tied to an account so
  /// a repeat rider's history means something, and a guest session has no
  /// durable identity to attach it to.
  void _maybePromptFeedback(String routeId, RouteDetail next) {
    if (isGuest || feedbackOpen) return;
    if (!next.tripJustCompleted) return;

    final tripEndedAt = next.live!.updatedAt.millisecondsSinceEpoch;
    final key = '$routeId@$tripEndedAt';
    if (_promptedTrips.contains(key)) return;

    _promptedTrips.add(key);
    _feedbackRouteId = routeId;
    _feedbackTripEndedAt = tripEndedAt;
    feedbackOpen = true;
    feedbackError = null;
    notifyListeners();
  }

  Future<void> submitFeedback({required int rating, String? comment}) async {
    final routeId = _feedbackRouteId;
    final tripEndedAt = _feedbackTripEndedAt;
    if (routeId == null || tripEndedAt == null) return;

    feedbackSubmitting = true;
    feedbackError = null;
    notifyListeners();
    try {
      await _repo.submitFeedback(
        routeId: routeId,
        rating: rating,
        tripEndedAt: tripEndedAt,
        comment: comment,
      );
      feedbackOpen = false;
    } on ApiException catch (e) {
      feedbackError = e.message;
    }
    feedbackSubmitting = false;
    notifyListeners();
  }

  void closeFeedback() {
    feedbackOpen = false;
    feedbackError = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Rider-assisted tracking
  // ---------------------------------------------------------------------

  void openCollab() {
    collabOpen = true;
    sharingError = null;
    notifyListeners();
  }

  void closeCollab() {
    collabOpen = false;
    notifyListeners();
  }

  Future<void> toggleSharing() async {
    if (sharing) {
      await _stopSharing(notifyServer: true);
      return;
    }

    final routeId = activeRouteId;
    if (routeId == null) return;

    sharingError = null;
    sharingErrorNeedsSettings = false;

    try {
      await _location.ensurePermission();
      await _repo.setSharing(routeId: routeId, active: true);

      await _location.start((position) {
        unawaited(
          _repo
              .submitRiderFix(
                routeId: routeId,
                lat: position.latitude,
                lng: position.longitude,
                speedKph: position.speed * 3.6,
                headingDeg: position.heading,
                accuracyM: position.accuracy,
              )
              // A dropped fix is not worth surfacing; the next one is seconds
              // away and the server treats the feed as best-effort.
              .catchError((_) {}),
        );
      });

      sharing = true;
    } on LocationException catch (e) {
      sharingError = e.message;
      sharingErrorNeedsSettings = e.needsAppSettings;
      sharing = false;
      // Roll back the server-side share if permission failed after we set it.
      unawaited(
        _repo.setSharing(routeId: routeId, active: false).catchError((_) => 0),
      );
    } on ApiException catch (e) {
      sharingError = e.message;
      sharing = false;
    }
    notifyListeners();
    unawaited(refreshDetail(quiet: true));
  }

  Future<void> _stopSharing({required bool notifyServer}) async {
    await _location.stop();
    final routeId = activeRouteId;
    if (notifyServer && routeId != null) {
      try {
        await _repo.setSharing(routeId: routeId, active: false);
      } on ApiException {
        // The server expires idle shares on its own, so a failure here only
        // delays the count dropping.
      }
    }
    sharing = false;
    notifyListeners();
  }

  Future<void> openLocationSettings() => _location.openAppSettings();
}
