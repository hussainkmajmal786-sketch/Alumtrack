import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/api_client.dart';
import '../data/auth_service.dart';
import '../data/bus_repository.dart';
import '../data/location_service.dart';
import '../models/bus.dart';
import '../models/stop.dart';

enum AppScreen { auth, list, bus, settings }

enum ThemeSetting { system, light, dark }

/// Loading lifecycle for a piece of remote data.
enum Loadable { idle, loading, ready, failed }

/// How often live data is refetched while its screen is visible.
const _listPollInterval = Duration(seconds: 10);
const _detailPollInterval = Duration(seconds: 5);

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

  // --- Navigation ------------------------------------------------------
  AppScreen screen = AppScreen.auth;
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
      screen = AppScreen.auth;
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
