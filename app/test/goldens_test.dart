import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:campus_bus_tracker/main.dart';
import 'package:campus_bus_tracker/state/app_state.dart';

/// The test binding otherwise substitutes a placeholder block-glyph font
/// for determinism; load the real bundled font so these captures reflect
/// actual production text metrics (this matters since several layouts
/// were tuned/verified against real glyph widths).
Future<void> _loadRealFont() async {
  final bytes = await File('assets/fonts/InterTight-Variable.ttf').readAsBytes();
  final loader = FontLoader('InterTight');
  loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();

  final iconBytes = await File(
    '${Platform.environment['FLUTTER_ROOT'] ?? '/home/claude/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  final iconLoader = FontLoader('MaterialIcons');
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

Future<void> _capture(WidgetTester tester, String name, void Function(AppState) configure) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final state = AppState();
  configure(state);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: const CampusBusTrackerApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await expectLater(find.byType(CampusBusTrackerApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(_loadRealFont);

  testWidgets('auth light', (tester) async {
    await _capture(tester, 'auth_light', (s) => s.themeSetting = ThemeSetting.light);
  });
  testWidgets('auth dark', (tester) async {
    await _capture(tester, 'auth_dark', (s) => s.themeSetting = ThemeSetting.dark);
  });
  testWidgets('bus list', (tester) async {
    await _capture(tester, 'bus_list', (s) {
      s.themeSetting = ThemeSetting.light;
      s.authed = true;
      s.screen = AppScreen.list;
    });
  });
  testWidgets('live status guest', (tester) async {
    await _capture(tester, 'live_status_guest', (s) {
      s.themeSetting = ThemeSetting.dark;
      s.authed = false;
      s.screen = AppScreen.bus;
    });
  });
  testWidgets('settings', (tester) async {
    await _capture(tester, 'settings', (s) {
      s.themeSetting = ThemeSetting.light;
      s.authed = true;
      s.screen = AppScreen.settings;
      s.cameFrom = AppScreen.bus;
    });
  });
  testWidgets('collab modal', (tester) async {
    await _capture(tester, 'collab_modal', (s) {
      s.themeSetting = ThemeSetting.dark;
      s.authed = false;
      s.screen = AppScreen.bus;
      s.collabOpen = true;
    });
  });
  testWidgets('notifications panel', (tester) async {
    await _capture(tester, 'notifications_panel', (s) {
      s.themeSetting = ThemeSetting.light;
      s.authed = true;
      s.screen = AppScreen.bus;
      s.notifOpen = true;
    });
  });
}
