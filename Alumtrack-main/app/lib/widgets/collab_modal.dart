import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'spring_drawer.dart';

const double _kCollabExtent = 520;

class CollabModal extends StatelessWidget {
  const CollabModal({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    return IgnorePointer(
      ignoring: !state.collabOpen,
      child: SpringDrawer(
        open: state.collabOpen,
        axis: DrawerAxis.vertical,
        extent: _kCollabExtent,
        builder: (context, offset, scrimOpacity) {
          return Stack(
            children: [
              if (scrimOpacity > 0)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: state.closeCollab,
                    child: Container(
                      color: Colors.black.withValues(
                        alpha: 0.32 * scrimOpacity,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: -offset,
                child: _CollabSheet(state: state, c: c),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CollabSheet extends StatelessWidget {
  final AppState state;
  final AppColors c;
  const _CollabSheet({required this.state, required this.c});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          boxShadow: c.sheetShadow,
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              color: c.glass,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 18),
                      decoration: BoxDecoration(
                        color: c.lab3,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: c.orangeBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.wifi_off_rounded,
                          size: 20,
                          color: c.orange,
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Help track this bus',
                              style: sfText(
                                size: 22,
                                weight: FontWeight.w700,
                                letterSpacing: -0.53,
                                color: c.label,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              state.detail?.number != null
                                  ? 'The onboard GPS on Route ${state.detail!.number} is reporting a weak signal. Riders sharing location keep arrival times accurate.'
                                  : 'The onboard GPS on this bus is reporting a weak signal. Riders sharing location keep arrival times accurate.',
                              style: sfText(
                                size: 14,
                                weight: FontWeight.w400,
                                color: c.lab2,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    decoration: BoxDecoration(
                      color: c.bgEl,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  "Share my location while I'm on this bus",
                                  style: sfText(
                                    size: 16,
                                    weight: FontWeight.w400,
                                    letterSpacing: -0.19,
                                    color: c.label,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              GestureDetector(
                                onTap: state.toggleSharing,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 240),
                                  width: 51,
                                  height: 31,
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: state.sharing ? c.green : c.fill,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: AnimatedAlign(
                                    duration: const Duration(milliseconds: 280),
                                    curve: Curves.easeOutCubic,
                                    alignment: state.sharing
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: Container(
                                      width: 27,
                                      height: 27,
                                      decoration: const BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: Color(0x33000000),
                                            blurRadius: 6,
                                            offset: Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          height: 1,
                          margin: const EdgeInsets.only(left: 16),
                          color: c.sep,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 13,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: c.green,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  state.ridersLabel,
                                  style: sfText(
                                    size: 14,
                                    weight: FontWeight.w500,
                                    color: c.label,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.verified_rounded,
                                size: 14,
                                color: c.acc,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'Verified by admin',
                                style: sfText(
                                  size: 12.5,
                                  weight: FontWeight.w500,
                                  color: c.acc,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: Material(
                      color: c.acc,
                      borderRadius: BorderRadius.circular(15),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(15),
                        onTap: state.closeCollab,
                        child: Center(
                          child: Text(
                            state.sharing ? 'Done' : 'Not now',
                            style: sfText(
                              size: 17,
                              weight: FontWeight.w600,
                              letterSpacing: -0.17,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      'Sharing stops automatically when you leave the route.',
                      textAlign: TextAlign.center,
                      style: sfText(
                        size: 12,
                        weight: FontWeight.w400,
                        color: c.lab3,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
