import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/stop.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/campus_map.dart';
import '../widgets/campus_map_3d.dart';
import '../widgets/draggable_sheet.dart';

class LiveStatusScreen extends StatefulWidget {
  const LiveStatusScreen({super.key});

  @override
  State<LiveStatusScreen> createState() => _LiveStatusScreenState();
}

class _LiveStatusScreenState extends State<LiveStatusScreen> {
  final GlobalKey<CampusMapState> _mapKey = GlobalKey<CampusMapState>();
  final GlobalKey<_MapControlsState> _controlsKey = GlobalKey<_MapControlsState>();
  final GlobalKey<_MyLocationButtonState> _myLocationKey = GlobalKey<_MyLocationButtonState>();
  final GlobalKey<CampusMap3DState> _map3DKey = GlobalKey<CampusMap3DState>();
  final ValueNotifier<double> _sheetFraction = ValueNotifier<double>(1);
  Stop? _selectedStop;

  /// Which map engine is showing. Defaults to the flat raster map: it is
  /// the proven path, works offline via the tile cache, and does not depend
  /// on a third-party vector tile host being reachable.
  bool _is3D = false;

  /// Aerial imagery instead of street tiles. Independent of [_is3D] — the
  /// 3D view has its own vector style and does not use these raster tiles.
  bool _isSatellite = false;

  /// Available on both platforms. Android needed a Gradle workaround for a
  /// maplibre_gl 0.27.0 bug on AGP 9 — see the comment in
  /// `android/build.gradle.kts` — without which the module fails to
  /// evaluate at all.
  static bool get _supports3D => true;

  @override
  void dispose() {
    _sheetFraction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    final detail = state.detail;

    if (detail == null) {
      return Container(
        color: c.bg,
        child: SafeArea(
          child: Stack(
            children: [
              _TopBar(state: state, c: c),
              Center(
                child: state.detailState == Loadable.failed
                    ? _DetailError(
                        message: state.detailError ?? 'Could not load this route.',
                        canRetry: state.detailErrorRetryable,
                        onRetry: () => state.refreshDetail(),
                        c: c,
                      )
                    : CircularProgressIndicator(color: c.acc),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: c.bg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Positioned.fill(
                child: (_is3D && _supports3D)
                    ? CampusMap3D(
                        key: _map3DKey,
                        dark: state.isDark,
                        stops: detail.stops,
                        live: detail.live,
                        roadPolyline: detail.roadPolyline,
                        stale: detail.live?.stale ?? false,
                      )
                    : CampusMap(
                        key: _mapKey,
                        dark: state.isDark,
                        stops: detail.stops,
                        live: detail.live,
                        roadPolyline: detail.roadPolyline,
                        stale: detail.live?.stale ?? false,
                        satellite: _isSatellite,
                        onStopTap: (stop) => setState(() => _selectedStop = stop),
                        onFollowStateChanged: (following, headingUp) =>
                            _controlsKey.currentState?.updateFollowState(following, headingUp),
                        onMyLocationAvailable: () =>
                            _myLocationKey.currentState?.markAvailable(),
                      ),
              ),
              _TopBar(state: state, c: c),
              if (detail.signal != BusSignal.good)
                _GpsWeakBanner(state: state, c: c, offline: detail.signal == BusSignal.offline),
              if (_supports3D)
                _ViewModeToggle(
                  fraction: _sheetFraction,
                  c: c,
                  is3D: _is3D,
                  onToggle: () => setState(() {
                    _is3D = !_is3D;
                    // A stop card opened in one view has no counterpart in
                    // the other, so clear it on the way across.
                    _selectedStop = null;
                  }),
                ),
              // These drive the flutter_map instance specifically; MapLibre
              // has its own gesture-based tilt/rotate and its own camera
              // helpers, so they would be inert (and misleading) in 3D.
              if (!(_is3D && _supports3D)) ...[
                _SatelliteToggle(
                  fraction: _sheetFraction,
                  c: c,
                  active: _isSatellite,
                  onToggle: () => setState(() => _isSatellite = !_isSatellite),
                ),
                _MapControls(
                  key: _controlsKey,
                  fraction: _sheetFraction,
                  c: c,
                  mapKey: _mapKey,
                ),
                _MyLocationButton(
                  key: _myLocationKey,
                  fraction: _sheetFraction,
                  c: c,
                  mapKey: _mapKey,
                ),
              ] else
                _Map3DControls(
                  fraction: _sheetFraction,
                  c: c,
                  mapKey: _map3DKey,
                ),
              if (_selectedStop != null)
                _StopDetailCard(
                  stop: _selectedStop!,
                  c: c,
                  onClose: () => setState(() => _selectedStop = null),
                ),
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
                      child: Builder(
                        builder: (context) {
                          final detail = state.detail;
                          final offline = detail == null ||
                              detail.signal == BusSignal.offline;
                          return Column(
                            children: [
                              Text(
                                detail == null ? 'Loading…' : 'Route ${detail.number}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: sfText(
                                  size: 17,
                                  weight: FontWeight.w600,
                                  letterSpacing: -0.26,
                                  color: c.label,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: offline ? c.lab3 : c.green,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: routeLabel(
                                      detail == null
                                          ? '—'
                                          : '${offline ? 'Offline' : 'Live'} · ${detail.name}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: sfText(
                                        size: 12,
                                        weight: FontWeight.w500,
                                        color: c.lab2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
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

  /// Offline means no usable fix at all, which riders cannot help with;
  /// weak means the position is coarse and more sharers would sharpen it.
  final bool offline;

  const _GpsWeakBanner({
    required this.state,
    required this.c,
    required this.offline,
  });

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
                            Text(
                              offline
                                  ? 'This bus is not reporting its location'
                                  : 'GPS signal weak on this bus',
                              style: sfText(size: 13.5, weight: FontWeight.w600, color: c.label),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              offline
                                  ? 'Share your location to track it'
                                  : 'Riders can improve accuracy',
                              style: sfText(size: 12, weight: FontWeight.w400, color: c.lab2),
                            ),
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

/// Three stacked map controls, Google-Maps-style: recenter (fit the whole
/// route), follow mode (lock the camera to the bus), and a compass toggle
/// for heading-up rotation. All fade with the sheet the same way the single
/// recenter button used to.
class _MapControls extends StatefulWidget {
  final ValueNotifier<double> fraction;
  final AppColors c;
  final GlobalKey<CampusMapState> mapKey;
  const _MapControls({
    super.key,
    required this.fraction,
    required this.c,
    required this.mapKey,
  });

  @override
  State<_MapControls> createState() => _MapControlsState();
}

class _MapControlsState extends State<_MapControls> {
  bool _following = false;
  bool _headingUp = false;

  /// Passed to [CampusMap.onFollowStateChanged] via the parent screen, kept
  /// in sync from the outside rather than read off `mapKey.currentState` at
  /// build time — that would go stale the moment a manual gesture silently
  /// breaks follow mode inside `CampusMapState`, since that setState only
  /// rebuilds the map itself, not this sibling widget.
  void updateFollowState(bool following, bool headingUp) {
    if (!mounted) return;
    setState(() {
      _following = following;
      _headingUp = headingUp;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final map = widget.mapKey.currentState;

    return Positioned(
      right: 14,
      bottom: 236,
      child: ValueListenableBuilder<double>(
        valueListenable: widget.fraction,
        builder: (context, f, _) {
          final opacity = f.clamp(0.0, 1.0);
          return IgnorePointer(
            ignoring: opacity < 0.05,
            child: Opacity(
              opacity: opacity,
              child: Transform.translate(
                offset: Offset(0, -(1 - opacity) * 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ControlButton(
                      c: c,
                      icon: Icons.explore_rounded,
                      active: _headingUp,
                      onTap: () => map?.toggleHeadingUp(),
                    ),
                    const SizedBox(height: 10),
                    _ControlButton(
                      c: c,
                      icon: Icons.directions_bus_filled_rounded,
                      active: _following,
                      onTap: () => map?.enterFollowMode(),
                    ),
                    const SizedBox(height: 10),
                    _ControlButton(
                      c: c,
                      icon: Icons.navigation_rounded,
                      active: false,
                      onTap: () => map?.recenter(),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final AppColors c;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  const _ControlButton({
    required this.c,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Material(
          color: active ? c.acc : c.glass,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: c.shadow),
              child: Icon(
                icon,
                size: 19,
                color: !enabled ? c.lab3 : (active ? Colors.white : c.acc),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Switches between the flat raster map and the tilted vector 3D one.
/// Sits apart from the other controls because it changes which map engine
/// is mounted, not just the camera.
class _ViewModeToggle extends StatelessWidget {
  final ValueNotifier<double> fraction;
  final AppColors c;
  final bool is3D;
  final VoidCallback onToggle;
  const _ViewModeToggle({
    required this.fraction,
    required this.c,
    required this.is3D,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      bottom: 396,
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(21),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Material(
                      color: is3D ? c.acc : c.glass,
                      child: InkWell(
                        onTap: onToggle,
                        child: Container(
                          width: 42,
                          height: 42,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(21),
                            boxShadow: c.shadow,
                          ),
                          child: Text(
                            is3D ? '3D' : '2D',
                            style: sfText(
                              size: 14,
                              weight: FontWeight.w700,
                              color: is3D ? Colors.white : c.acc,
                            ),
                          ),
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

/// Switches the 2D map between street tiles and aerial imagery. Sits below
/// the 2D/3D toggle; hidden in 3D, which uses its own vector style rather
/// than these raster tiles.
class _SatelliteToggle extends StatelessWidget {
  final ValueNotifier<double> fraction;
  final AppColors c;
  final bool active;
  final VoidCallback onToggle;
  const _SatelliteToggle({
    required this.fraction,
    required this.c,
    required this.active,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      bottom: 344,
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
                child: _ControlButton(
                  c: c,
                  icon: active ? Icons.map_rounded : Icons.satellite_alt_rounded,
                  active: active,
                  onTap: onToggle,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Camera controls for the 3D map. Kept separate from [_MapControls]
/// because MapLibre exposes its own camera API — the flutter_map controls
/// would be operating on a widget that is not even mounted in 3D mode.
class _Map3DControls extends StatelessWidget {
  final ValueNotifier<double> fraction;
  final AppColors c;
  final GlobalKey<CampusMap3DState> mapKey;
  const _Map3DControls({
    required this.fraction,
    required this.c,
    required this.mapKey,
  });

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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ControlButton(
                      c: c,
                      icon: Icons.directions_bus_filled_rounded,
                      active: false,
                      onTap: () => mapKey.currentState?.followBus(),
                    ),
                    const SizedBox(height: 10),
                    _ControlButton(
                      c: c,
                      icon: Icons.zoom_out_map_rounded,
                      active: false,
                      onTap: () => mapKey.currentState?.resetView(),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Maps' own "My Location" button: bottom-left, jumps the camera to the
/// rider's own GPS dot. Disabled (dimmed, inert) until a first fix arrives —
/// see [CampusMap.onMyLocationAvailable].
class _MyLocationButton extends StatefulWidget {
  final ValueNotifier<double> fraction;
  final AppColors c;
  final GlobalKey<CampusMapState> mapKey;
  const _MyLocationButton({
    super.key,
    required this.fraction,
    required this.c,
    required this.mapKey,
  });

  @override
  State<_MyLocationButton> createState() => _MyLocationButtonState();
}

class _MyLocationButtonState extends State<_MyLocationButton> {
  bool _available = false;

  void markAvailable() {
    if (!mounted || _available) return;
    setState(() => _available = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final map = widget.mapKey.currentState;

    return Positioned(
      left: 14,
      bottom: 236,
      child: ValueListenableBuilder<double>(
        valueListenable: widget.fraction,
        builder: (context, f, _) {
          final opacity = f.clamp(0.0, 1.0);
          return IgnorePointer(
            ignoring: opacity < 0.05 || !_available,
            child: Opacity(
              opacity: opacity,
              child: Transform.translate(
                offset: Offset(0, -(1 - opacity) * 24),
                child: _ControlButton(
                  c: c,
                  icon: Icons.my_location_rounded,
                  active: false,
                  onTap: _available ? () => map?.recenterOnMyLocation() : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Google-Maps-style POI card: tapping a stop shows its name, ETA, and
/// distance without leaving the map or opening the full sheet.
class _StopDetailCard extends StatelessWidget {
  final Stop stop;
  final AppColors c;
  final VoidCallback onClose;
  const _StopDetailCard({required this.stop, required this.c, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final eta = stop.etaSeconds;
    final km = stop.distanceM != null ? stop.distanceM! / 1000 : null;

    return Positioned(
      left: 14,
      right: 14,
      bottom: 250,
      child: SafeArea(
        top: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              decoration: BoxDecoration(
                color: c.glass,
                borderRadius: BorderRadius.circular(18),
                boxShadow: c.shadow,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stop.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sfText(
                            size: 16,
                            weight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: c.label,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          stop.state == StopState.past
                              ? 'Already passed'
                              : eta != null
                                  ? '${(eta / 60).ceil().clamp(1, 999)} min'
                                          '${km != null ? ' · ${km < 1 ? '${stop.distanceM!.round()} m' : '${km.toStringAsFixed(1)} km'}' : ''}'
                                  : stop.scheduledAt ?? 'No live ETA yet',
                          style: sfText(size: 13.5, weight: FontWeight.w400, color: c.lab2),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: Icon(Icons.close_rounded, size: 20, color: c.lab3),
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

class _DetailError extends StatelessWidget {
  final String message;
  final bool canRetry;
  final VoidCallback onRetry;
  final AppColors c;

  const _DetailError({
    required this.message,
    required this.canRetry,
    required this.onRetry,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 40, color: c.lab3),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: sfText(size: 15, weight: FontWeight.w500, color: c.label, height: 1.4),
          ),
          if (canRetry) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: onRetry,
              child: Text(
                'Try again',
                style: sfText(size: 15, weight: FontWeight.w600, color: c.acc),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
