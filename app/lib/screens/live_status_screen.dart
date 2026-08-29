import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/campus_map.dart';
import '../widgets/draggable_sheet.dart';

class LiveStatusScreen extends StatefulWidget {
  const LiveStatusScreen({super.key});

  @override
  State<LiveStatusScreen> createState() => _LiveStatusScreenState();
}

class _LiveStatusScreenState extends State<LiveStatusScreen> {
  final GlobalKey<CampusMapState> _mapKey = GlobalKey<CampusMapState>();
  final ValueNotifier<double> _sheetFraction = ValueNotifier<double>(1);

  @override
  void dispose() {
    _sheetFraction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    return Container(
      color: c.bg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Positioned.fill(child: CampusMap(key: _mapKey, dark: state.isDark)),
              _TopBar(state: state, c: c),
              if (state.gpsWeak) _GpsWeakBanner(state: state, c: c),
              _RecenterButton(fraction: _sheetFraction, c: c, onTap: () => _mapKey.currentState?.recenter()),
              DraggableSheet(
                totalHeight: constraints.maxHeight,
                state: state,
                c: c,
                fraction: _sheetFraction,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final AppState state;
  final AppColors c;
  const _TopBar({required this.state, required this.c});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(color: c.glass, border: Border(bottom: BorderSide(color: c.sep, width: 0.5))),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 10),
                child: Row(
                  children: [
                    _CircleButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      color: c.acc,
                      onTap: state.backFromBus,
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text('Route 12', style: sfText(size: 17, weight: FontWeight.w600, letterSpacing: -0.26, color: c.label)),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(width: 6, height: 6, decoration: BoxDecoration(color: c.green, shape: BoxShape.circle)),
                              const SizedBox(width: 5),
                              routeLabel('Live · Kottayam ⇄ CEK', style: sfText(size: 12, weight: FontWeight.w500, color: c.lab2)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _CircleButton(icon: Icons.notifications_none_rounded, color: c.acc, onTap: state.openNotif),
                        if (state.badge > 0)
                          Positioned(
                            top: 3,
                            right: 3,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 16),
                              height: 16,
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(color: const Color(0xFFFF3B30), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.glass, width: 1.5)),
                              alignment: Alignment.center,
                              child: Text('${state.badge}', style: sfText(size: 10, weight: FontWeight.w700, color: Colors.white)),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(icon, size: 19, color: color),
      ),
    );
  }
}

class _GpsWeakBanner extends StatelessWidget {
  final AppState state;
  final AppColors c;
  const _GpsWeakBanner({required this.state, required this.c});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 114,
      left: 14,
      right: 14,
      child: SafeArea(
        bottom: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Material(
              color: c.glass,
              borderRadius: BorderRadius.circular(15),
              child: InkWell(
                borderRadius: BorderRadius.circular(15),
                onTap: state.openCollab,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), boxShadow: c.shadow),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(color: c.orangeBg, borderRadius: BorderRadius.circular(9)),
                        child: Icon(Icons.wifi_off_rounded, size: 15, color: c.orange),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('GPS signal weak on this bus', style: sfText(size: 13.5, weight: FontWeight.w600, color: c.label)),
                            const SizedBox(height: 2),
                            Text('Riders can improve accuracy', style: sfText(size: 12, weight: FontWeight.w400, color: c.lab2)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 16, color: c.lab3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecenterButton extends StatelessWidget {
  final ValueNotifier<double> fraction;
  final AppColors c;
  final VoidCallback onTap;
  const _RecenterButton({required this.fraction, required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      bottom: 236,
      child: ValueListenableBuilder<double>(
        valueListenable: fraction,
        builder: (context, f, _) {
          final opacity = f.clamp(0.0, 1.0);
          return IgnorePointer(
            ignoring: opacity < 0.05,
            child: Opacity(
              opacity: opacity,
              child: Transform.translate(
                offset: Offset(0, -(1 - opacity) * 24),
                child: ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Material(
                      color: c.glass,
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: onTap,
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: c.shadow),
                          child: Icon(Icons.navigation_rounded, size: 19, color: c.acc),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
