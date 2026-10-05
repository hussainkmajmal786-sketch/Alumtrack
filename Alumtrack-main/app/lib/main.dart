import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/env.dart';
import 'data/api_client.dart';
import 'data/auth_service.dart';
import 'data/bus_repository.dart';
import 'screens/auth_screen.dart';
import 'screens/landing_screen.dart';
import 'screens/bus_list_screen.dart';
import 'screens/live_status_screen.dart';
import 'screens/admin/admin_dashboard_screen.dart';
import 'screens/admin/admin_login_screen.dart';
import 'screens/student_email_auth_screen.dart';
import 'screens/settings_screen.dart';
import 'state/app_state.dart';
import 'theme/app_colors.dart';
import 'theme/app_text.dart';
import 'widgets/collab_modal.dart';
import 'widgets/feedback_modal.dart';
import 'widgets/notification_panel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final misconfiguration = Env.misconfiguration;
  if (misconfiguration != null) {
    runApp(_MisconfiguredApp(reason: misconfiguration));
    return;
  }

  final api = ApiClient();
  final state = AppState(
    api: api,
    auth: AuthService(api),
    repository: BusRepository(api),
  );

  runApp(
    ChangeNotifierProvider.value(
      value: state..bootstrap(),
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
      title: 'Alumtrack',
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

    if (state.bootstrapping) {
      return Scaffold(
        backgroundColor: c.bg,
        body: Center(child: CircularProgressIndicator(color: c.acc)),
      );
    }

    Widget screen;
    switch (state.screen) {
      case AppScreen.landing:
        screen = const LandingScreen(key: ValueKey('landing'));
        break;
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
      case AppScreen.adminAuth:
        screen = const AdminLoginScreen(key: ValueKey('adminAuth'));
        break;
      case AppScreen.adminDashboard:
        screen = const AdminDashboardScreen(key: ValueKey('adminDashboard'));
        break;
      case AppScreen.studentEmailAuth:
        screen = const StudentEmailAuthScreen(key: ValueKey('studentEmailAuth'));
        break;
    }

    return PopScope(
      canPop: state.screen == AppScreen.landing,
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
          case AppScreen.adminAuth:
            state.adminBackToAuth();
            break;
          case AppScreen.adminDashboard:
            state.adminSignOut();
            break;
          case AppScreen.studentEmailAuth:
            state.studentEmailBackToAuth();
            break;
          case AppScreen.auth:
            state.goToLandingFromAuth();
            break;
          case AppScreen.landing:
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
            const FeedbackModal(),
            const NotificationPanel(),
          ],
        ),
      ),
    );
  }
}

/// Shown when the build is missing its backend configuration, rather than
/// letting every request fail with an opaque network error.
class _MisconfiguredApp extends StatelessWidget {
  final String reason;
  const _MisconfiguredApp({required this.reason});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF2F2F7),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.settings_ethernet_rounded,
                    size: 48, color: Color(0xFF8E8E93)),
                const SizedBox(height: 16),
                Text(
                  'Backend not configured',
                  textAlign: TextAlign.center,
                  style: sfText(
                    size: 20,
                    weight: FontWeight.w700,
                    color: const Color(0xFF000000),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: sfText(
                    size: 14,
                    color: const Color(0x993C3C43),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Rebuild with:\n'
                  '--dart-define=API_BASE_URL=https://<worker>.workers.dev',
                  textAlign: TextAlign.center,
                  style: sfText(
                    size: 12,
                    color: const Color(0x663C3C43),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
