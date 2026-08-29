import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    return Container(
      color: c.bg,
      child: Stack(
        children: [
          Positioned(
            top: -140,
            left: -80,
            child: _Blob(color: c.accSoft, size: 420),
          ),
          Positioned(
            bottom: -120,
            right: -100,
            child: _Blob(color: c.accSoft, size: 380),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(34, 0, 34, 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: c.acc,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: c.shadow,
                    ),
                    child: const Icon(Icons.directions_bus_filled_rounded, color: Colors.white, size: 38),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    'Campus\nBus Tracker',
                    textAlign: TextAlign.center,
                    style: sfText(size: 34, weight: FontWeight.w700, letterSpacing: -1.09, color: c.label, height: 1.08),
                  ),
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      'Live arrivals for every route between Kottayam and CEK Kidangoor.',
                      textAlign: TextAlign.center,
                      style: sfText(size: 16, weight: FontWeight.w400, color: c.lab2, height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 56),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: Material(
                      color: c.acc,
                      borderRadius: BorderRadius.circular(15),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(15),
                        onTap: state.signInGoogle,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.92),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              alignment: Alignment.center,
                              child: Text('G', style: sfText(size: 13, weight: FontWeight.w700, color: c.acc)),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                'Continue with Google',
                                overflow: TextOverflow.ellipsis,
                                style: sfText(size: 16.5, weight: FontWeight.w600, letterSpacing: -0.16, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: state.continueGuest,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Text(
                        'Continue as Guest',
                        style: sfText(size: 15, weight: FontWeight.w500, color: c.acc),
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                  Text(
                    'Location is used only while you track a bus.',
                    textAlign: TextAlign.center,
                    style: sfText(size: 12, weight: FontWeight.w400, color: c.lab3, height: 1.4),
                  ),
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
