import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// The app's true entry point: wordmark, a one-line pitch, and a single
/// "Get Started" action into sign-in. Deliberately shows nothing about
/// accounts or roles — that choice belongs to the auth screen that follows.
///
/// Admin access has no visible link anywhere in the student-facing flow;
/// a long-press on the logo mark is the only way in; see
/// [AppState.goAdminAuthFromLanding].
class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    return Container(
      color: c.bg,
      child: Stack(
        children: [
          Positioned(
            top: -160,
            right: -120,
            child: _Blob(color: c.accSoft, size: 460),
          ),
          Positioned(
            bottom: -140,
            left: -100,
            child: _Blob(color: c.accSoft, size: 400),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(34, 0, 34, 44),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  GestureDetector(
                    onLongPress: state.goAdminAuthFromLanding,
                    child: Column(
                      children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            color: c.acc,
                            borderRadius: BorderRadius.circular(26),
                            boxShadow: c.shadow,
                          ),
                          child: const Icon(
                            Icons.directions_bus_filled_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          'Campus\nBus Tracker',
                          textAlign: TextAlign.center,
                          style: sfText(
                            size: 38,
                            weight: FontWeight.w700,
                            letterSpacing: -1.2,
                            color: c.label,
                            height: 1.06,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: Text(
                      'Know exactly where your bus is, every stop of the way.',
                      textAlign: TextAlign.center,
                      style: sfText(
                        size: 16.5,
                        weight: FontWeight.w400,
                        color: c.lab2,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const Spacer(flex: 4),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: Material(
                      color: c.acc,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: state.goAuthFromLanding,
                        child: Center(
                          child: Text(
                            'Get Started',
                            style: sfText(
                              size: 17,
                              weight: FontWeight.w600,
                              letterSpacing: -0.2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;
  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}
