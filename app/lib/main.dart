import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'state/app_state.dart';
import 'theme/app_colors.dart';
import 'screens/auth_screen.dart';
import 'screens/bus_list_screen.dart';
import 'screens/live_status_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/collab_modal.dart';
import 'widgets/notification_panel.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const CampusBusTrackerApp(),
    ),
  );
}

class CampusBusTrackerApp extends StatelessWidget {
  const CampusBusTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;
    return MaterialApp(
      title: 'Campus Bus Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: state.isDark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: c.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: c.acc,
          brightness: state.isDark ? Brightness.dark : Brightness.light,
        ),
      ),
      home: const _RootScaffold(),
    );
  }
}

class _RootScaffold extends StatelessWidget {
  const _RootScaffold();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    Widget screen;
    switch (state.screen) {
      case AppScreen.auth:
        screen = const AuthScreen(key: ValueKey('auth'));
        break;
      case AppScreen.list:
        screen = const BusListScreen(key: ValueKey('list'));
        break;
      case AppScreen.bus:
        screen = const LiveStatusScreen(key: ValueKey('bus'));
        break;
      case AppScreen.settings:
        screen = const SettingsScreen(key: ValueKey('settings'));
        break;
    }

    return PopScope(
      canPop: state.screen == AppScreen.auth,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        switch (state.screen) {
          case AppScreen.list:
            state.goAuth();
            break;
          case AppScreen.bus:
            state.backFromBus();
            break;
          case AppScreen.settings:
            state.backFromSettings();
            break;
          case AppScreen.auth:
            break;
        }
      },
      child: Scaffold(
        backgroundColor: c.bg,
        body: Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
                  child: child,
                ),
              ),
              child: screen,
            ),
            const CollabModal(),
            const NotificationPanel(),
          ],
        ),
      ),
    );
  }
}
