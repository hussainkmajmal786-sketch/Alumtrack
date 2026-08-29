import 'dart:async';
import 'dart:math';
import 'package:flutter/widgets.dart';

enum AppScreen { auth, list, bus, settings }

enum ThemeSetting { system, light, dark }

/// Ports the interaction/navigation logic of the prototype's `Component`
/// class (Campus Bus Tracker.dc.html) into a plain app-wide state object.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState() {
    WidgetsBinding.instance.addObserver(this);
    systemDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  }

  AppScreen screen = AppScreen.auth;
  AppScreen? cameFrom;
  ThemeSetting themeSetting = ThemeSetting.system;
  late bool systemDark;

  bool authed = false;
  String query = '';
  String updated = 'just now';

  bool sharing = false;
  int riders = 3;
  Timer? _riderTimer;

  bool notifOpen = false;
  bool notifEmpty = false;
  int badge = 2;

  bool collabOpen = false;

  String lead = '5 min';
  int eta = 6;

  final bool gpsWeak = true;

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

  bool get isGuest => !authed;

  String get settingsBackLabel => cameFrom == AppScreen.bus ? 'Route 12' : 'Buses';

  String get appearanceNote {
    switch (themeSetting) {
      case ThemeSetting.system:
        return 'Following your device appearance — currently ${systemDark ? 'Dark' : 'Light'}.';
      case ThemeSetting.light:
        return 'Always Light, regardless of system setting.';
      case ThemeSetting.dark:
        return 'Always Dark, regardless of system setting.';
    }
  }

  String get ridersLabel => '$riders ${riders == 1 ? 'rider sharing' : 'riders sharing'}';

  @override
  void didChangePlatformBrightness() {
    systemDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    notifyListeners();
  }

  void _go(AppScreen next) {
    notifOpen = false;
    collabOpen = false;
    screen = next;
    notifyListeners();
  }

  void goAuth() {
    authed = false;
    _go(AppScreen.auth);
  }

  void goList() {
    authed = true;
    _go(AppScreen.list);
  }

  void goBus() => _go(AppScreen.bus);

  void goSettings() {
    cameFrom = screen;
    _go(AppScreen.settings);
  }

  void signInGoogle() {
    authed = true;
    _go(AppScreen.list);
  }

  void continueGuest() {
    authed = false;
    _go(AppScreen.bus);
  }

  void backFromBus() => authed ? _go(AppScreen.list) : _go(AppScreen.auth);

  void backFromSettings() => _go(cameFrom == AppScreen.bus ? AppScreen.bus : AppScreen.list);

  void setTheme(ThemeSetting t) {
    themeSetting = t;
    notifyListeners();
  }

  void setLead(String v) {
    lead = v;
    notifyListeners();
  }

  void setQuery(String v) {
    query = v;
    notifyListeners();
  }

  void toggleEmptyNotifs() {
    notifEmpty = !notifEmpty;
    notifyListeners();
  }

  void openNotif() {
    notifOpen = true;
    badge = 0;
    notifyListeners();
  }

  void closeNotif() {
    notifOpen = false;
    notifyListeners();
  }

  void openCollab() {
    collabOpen = true;
    notifyListeners();
  }

  void closeCollab() {
    collabOpen = false;
    notifyListeners();
  }

  void toggleSharing() {
    final on = !sharing;
    sharing = on;
    riders = on ? riders + 1 : max(1, riders - 1);
    _riderTimer?.cancel();
    _riderTimer = null;
    if (on) {
      _riderTimer = Timer.periodic(const Duration(milliseconds: 4200), (_) {
        final d = Random().nextBool() ? -1 : 1;
        riders = riders + d;
        if (riders < 2) riders = 2;
        if (riders > 9) riders = 9;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    await Future<void>.delayed(const Duration(milliseconds: 950));
    updated = 'just now';
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _riderTimer?.cancel();
    super.dispose();
  }
}
