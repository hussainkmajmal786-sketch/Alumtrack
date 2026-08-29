import 'dart:io';

import 'package:campus_bus_tracker/data/auth_service.dart';
import 'package:campus_bus_tracker/main.dart';
import 'package:campus_bus_tracker/state/app_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fake_backend.dart';
import 'plugin_mocks.dart';
import 'widget_test.dart' show buildState;

/// The test binding otherwise substitutes a placeholder block-glyph font for
/// determinism; load the real bundled fonts so these captures reflect actual
/// production text metrics and icon glyphs.
Future<void> _loadRealFonts() async {
  final bytes = await File('assets/fonts/InterTight-Variable.ttf').readAsBytes();
  final loader = FontLoader('InterTight');
  loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();

  final iconBytes = await File(
    '${Platform.environment['FLUTTER_ROOT'] ?? '/home/claude/flutter'}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  final iconLoader = FontLoader('MaterialIcons');
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

Future<void> _capture(
  WidgetTester tester,
  String name,
  FakeBackend backend,
  Future<void> Function(AppState state) configure,
) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));

  final state = buildState(backend)..bootstrapping = false;
  await configure(state);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: const CampusBusTrackerApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));

  await expectLater(
    find.byType(CampusBusTrackerApp),
    matchesGoldenFile('goldens/$name.png'),
  );

  state.dispose();
}

const _signedIn = Session(token: 't', subject: 'google:test', isGuest: false);
const _guest = Session(token: 't', subject: 'guest:test', isGuest: true);

void main() {
  setUpAll(() async {
    installPluginMocks();
    await _loadRealFonts();
  });

  testWidgets('auth light', (tester) async {
    await _capture(tester, 'auth_light', FakeBackend(), (s) async {
      s.themeSetting = ThemeSetting.light;
    });
  });

  testWidgets('auth dark', (tester) async {
    await _capture(tester, 'auth_dark', FakeBackend(), (s) async {
      s.themeSetting = ThemeSetting.dark;
    });
  });

  testWidgets('bus list', (tester) async {
    final backend = FakeBackend(
      routes: [
        FakeBackend.route(id: 'r1', number: '12'),
        FakeBackend.route(
          id: 'r2',
          number: '04',
          name: 'Town ⇄ Ayarkunnam',
          status: 'late',
          etaSeconds: 1080,
          delaySeconds: 420,
        ),
        FakeBackend.route(
          id: 'r3',
          number: '27',
          name: 'Manthadi Loop',
          status: 'weak',
          etaSeconds: 660,
        ),
        FakeBackend.route(
          id: 'r4',
          number: '33',
          name: 'Oravakal ⇄ Malam',
          status: 'offline',
          etaSeconds: null,
        ),
      ],
    );
    await _capture(tester, 'bus_list', backend, (s) async {
      s.themeSetting = ThemeSetting.light;
      s.session = _signedIn;
      await s.refreshList();
      s.screen = AppScreen.list;
    });
  });

  testWidgets('live status guest', (tester) async {
    final backend = FakeBackend(detail: FakeBackend.routeDetail());
    await _capture(tester, 'live_status_guest', backend, (s) async {
      s.themeSetting = ThemeSetting.dark;
      s.session = _guest;
      s.activeRouteId = 'r1';
      await s.refreshDetail();
      s.screen = AppScreen.bus;
    });
  });

  testWidgets('live status offline', (tester) async {
    final backend = FakeBackend(
      detail: FakeBackend.routeDetail(
        status: 'offline',
        signal: 'offline',
        withLive: false,
      ),
    );
    await _capture(tester, 'live_status_offline', backend, (s) async {
      s.themeSetting = ThemeSetting.dark;
      s.session = _signedIn;
      s.activeRouteId = 'r1';
      await s.refreshDetail();
      s.screen = AppScreen.bus;
    });
  });

  testWidgets('settings', (tester) async {
    final backend = FakeBackend(detail: FakeBackend.routeDetail());
    await _capture(tester, 'settings', backend, (s) async {
      s.themeSetting = ThemeSetting.light;
      s.session = _signedIn;
      s.activeRouteId = 'r1';
      await s.refreshDetail();
      s.cameFrom = AppScreen.bus;
      s.screen = AppScreen.settings;
    });
  });

  testWidgets('collab modal', (tester) async {
    final backend = FakeBackend(detail: FakeBackend.routeDetail());
    await _capture(tester, 'collab_modal', backend, (s) async {
      s.themeSetting = ThemeSetting.dark;
      s.session = _guest;
      s.activeRouteId = 'r1';
      await s.refreshDetail();
      s.screen = AppScreen.bus;
      s.collabOpen = true;
    });
  });

  testWidgets('notifications panel', (tester) async {
    final backend = FakeBackend(
      detail: FakeBackend.routeDetail(),
      unread: 2,
      alerts: [
        FakeBackend.alert(id: 'a1'),
        FakeBackend.alert(
          id: 'a2',
          kind: 'delay',
          message: 'Route 12 delayed 7 min near Ayarkunnam',
          hour: 8,
          minute: 58,
        ),
        FakeBackend.alert(
          id: 'a3',
          kind: 'signal',
          message: 'GPS signal restored on Route 27',
          routeNumber: '27',
          unread: false,
          hour: 8,
          minute: 41,
        ),
      ],
    );
    await _capture(tester, 'notifications_panel', backend, (s) async {
      s.themeSetting = ThemeSetting.light;
      s.session = _signedIn;
      s.activeRouteId = 'r1';
      await s.refreshDetail();
      await s.refreshAlerts();
      s.screen = AppScreen.bus;
      s.notifOpen = true;
    });
  });

  testWidgets('empty alerts', (tester) async {
    final backend = FakeBackend(detail: FakeBackend.routeDetail());
    await _capture(tester, 'notifications_empty', backend, (s) async {
      s.themeSetting = ThemeSetting.dark;
      s.session = _signedIn;
      s.activeRouteId = 'r1';
      await s.refreshDetail();
      await s.refreshAlerts();
      s.screen = AppScreen.bus;
      s.notifOpen = true;
    });
  });
}
