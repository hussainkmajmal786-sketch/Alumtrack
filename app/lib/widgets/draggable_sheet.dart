import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/stop.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/spring_runner.dart';

/// Ports the prototype's draggable bottom sheet: 1:1 pointer-tracked,
/// rubber-bands at both bounds, projects release momentum (Apple's
/// exponential decay), and snaps with a velocity-carrying spring.
class DraggableSheet extends StatefulWidget {
  final double totalHeight;
  final AppState state;
  final AppColors c;
  final ValueNotifier<double> fraction; // 0 = expanded, 1 = collapsed

  const DraggableSheet({
    super.key,
    required this.totalHeight,
    required this.state,
    required this.c,
    required this.fraction,
  });

  @override
  State<DraggableSheet> createState() => DraggableSheetState();
}

class DraggableSheetState extends State<DraggableSheet>
    with SingleTickerProviderStateMixin {
  late final SpringRunner _spring = SpringRunner(this);
  late final ScrollController _scrollController = ScrollController();

  static const double _sheetHeightRatio = 648 / 852;
  static const double _downRatio = 444 / 852;

  double get _sheetHeight => widget.totalHeight * _sheetHeightRatio;
  double get _sheetDown => widget.totalHeight * _downRatio;

  double _y = 0;
  bool _expanded = false;
  bool _initialized = false;

  double _rubber(double over, double dim, [double k = 0.55]) =>
      (over * dim * k) / (dim + k * over.abs());

  @override
  void didUpdateWidget(covariant DraggableSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_initialized || oldWidget.totalHeight != widget.totalHeight) {
      _resetCollapsed();
    }
  }

  void _resetCollapsed() {
    _initialized = true;
    _y = _sheetDown;
    _expanded = false;
    widget.fraction.value = 1;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void collapse() {
    _spring.animateTo(
      _sheetDown,
      from: _y,
      bounce: 0.18,
      response: 0.34,
      onUpdate: _setY,
    );
    _setExpanded(false);
  }

  void _setY(double y) {
    setState(() => _y = y);
    widget.fraction.value = (_y / _sheetDown).clamp(0.0, 1.0);
  }

  void _setExpanded(bool expanded) {
    if (_expanded == expanded) return;
    setState(() => _expanded = expanded);
    if (!expanded && _scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _spring.stop();
    var y = _y + d.delta.dy;
    if (y < 0) y = _rubber(y, 400);
    if (y > _sheetDown) y = _sheetDown + _rubber(y - _sheetDown, 300);
    _setY(y);
  }

  void _onDragEnd(DragEndDetails d) {
    final vel = d.primaryVelocity ?? 0;
    final projected = _y + (vel / 1000 * 0.998) / (1 - 0.998);
    final mid = _sheetDown / 2;
    final target = projected < mid ? 0.0 : _sheetDown;
    _setExpanded(target == 0);
    _spring.animateTo(
      target,
      from: _y,
      bounce: 0.18,
      response: 0.34,
      velocity: vel,
      onUpdate: _setY,
    );
  }

  @override
  void dispose() {
    _spring.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) _resetCollapsed();
    final c = widget.c;
    final state = widget.state;
    final detail = state.detail;
    final stops = detail?.stops ?? const <Stop>[];

    final etaMinutes = detail?.etaMinutes;
    final etaText = etaMinutes?.toString() ?? '—';

    final Color statusBg;
    final Color statusFg;
    final IconData statusIcon;
    final String statusLabel;
    switch (detail?.status ?? BusStatusView.offline) {
      case BusStatusView.onTime:
        statusBg = c.greenBg;
        statusFg = c.green;
        statusIcon = Icons.check_rounded;
        statusLabel = 'On time';
        break;
      case BusStatusView.late:
        statusBg = c.orangeBg;
        statusFg = c.orange;
        statusIcon = Icons.schedule_rounded;
        final delay = ((detail?.live?.delaySeconds ?? 0) / 60).round();
        statusLabel = 'Delayed ${delay < 1 ? 1 : delay} min';
        break;
      case BusStatusView.weak:
        statusBg = c.orangeBg;
        statusFg = c.orange;
        statusIcon = Icons.wifi_off_rounded;
        statusLabel = 'Approximate';
        break;
      case BusStatusView.offline:
        statusBg = c.grayBg;
        statusFg = c.gray;
        statusIcon = Icons.block_rounded;
        statusLabel = 'Offline';
        break;
    }

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: _sheetHeight,
      child: Transform.translate(
        offset: Offset(0, _y),
        child: Container(
          decoration: BoxDecoration(
            color: c.glass,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            boxShadow: c.sheetShadow,
          ),
          clipBehavior: Clip.antiAlias,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: _onDragEnd,
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 38,
                        height: 5,
                        decoration: BoxDecoration(
                          color: c.lab3,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'NEXT STOP',
                                    style: sfText(
                                      size: 12,
                                      weight: FontWeight.w500,
                                      letterSpacing: 0.7,
                                      color: c.lab2,
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    detail?.nextStop?.name ?? '—',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: sfText(
                                      size: 22,
                                      weight: FontWeight.w600,
                                      letterSpacing: -0.44,
                                      color: c.label,
                                    ),
                                  ),
                                  const SizedBox(height: 9),
                                  Container(
                                    padding: const EdgeInsets.fromLTRB(
                                      7,
                                      4,
                                      9,
                                      4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: statusBg,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          statusIcon,
                                          size: 12,
                                          color: statusFg,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          statusLabel,
                                          style: sfText(
                                            size: 11.5,
                                            weight: FontWeight.w600,
                                            color: statusFg,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    etaText,
                                    style: sfText(
                                      size: 62,
                                      weight: FontWeight.w700,
                                      letterSpacing: -2.8,
                                      color: c.label,
                                      height: 0.9,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      'min',
                                      style: sfText(
                                        size: 19,
                                        weight: FontWeight.w600,
                                        letterSpacing: -0.38,
                                        color: c.lab2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        color: c.sep,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: _scrollController,
                    physics: _expanded
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Upcoming stops',
                              overflow: TextOverflow.ellipsis,
                              style: sfText(
                                size: 15,
                                weight: FontWeight.w600,
                                letterSpacing: -0.19,
                                color: c.label,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            detail?.scheduledArrival == null
                                ? ''
                                : 'Arrives ${detail!.stops.isEmpty ? '' : detail.stops.last.name.split(' ').first} ${detail.scheduledArrival}',
                            style: sfText(
                              size: 12.5,
                              weight: FontWeight.w400,
                              color: c.lab2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      for (var i = 0; i < stops.length; i++)
                        _StopTimelineRow(
                          stop: stops[i],
                          isFirst: i == 0,
                          isLast: i == stops.length - 1,
                          nextEtaMinutes: etaMinutes,
                          delaySeconds: detail?.live?.delaySeconds,
                          c: c,
                        ),
                      if (state.isGuest)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: state.goAuth,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                13,
                                16,
                                13,
                              ),
                              decoration: BoxDecoration(
                                color: c.accSoft,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.lock_outline_rounded,
                                    size: 18,
                                    color: c.acc,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Sign in to see all 6 routes',
                                          style: sfText(
                                            size: 14,
                                            weight: FontWeight.w600,
                                            color: c.label,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Guests can track one linked bus',
                                          style: sfText(
                                            size: 12.5,
                                            weight: FontWeight.w400,
                                            color: c.lab2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 16,
                                    color: c.acc,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: state.openCollab,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                            decoration: BoxDecoration(
                              color: c.fill,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.people_alt_rounded,
                                  size: 19,
                                  color: c.acc,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Rider-assisted tracking',
                                        style: sfText(
                                          size: 14,
                                          weight: FontWeight.w600,
                                          color: c.label,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${state.ridersLabel} on this bus',
                                        style: sfText(
                                          size: 12.5,
                                          weight: FontWeight.w400,
                                          color: c.lab2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 16,
                                  color: c.lab3,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: state.goSettings,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                            decoration: BoxDecoration(
                              color: c.fill,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.settings_outlined,
                                  size: 19,
                                  color: c.lab2,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Settings',
                                        style: sfText(
                                          size: 14,
                                          weight: FontWeight.w600,
                                          color: c.label,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Appearance, alerts, linked bus',
                                        style: sfText(
                                          size: 12.5,
                                          weight: FontWeight.w400,
                                          color: c.lab2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 16,
                                  color: c.lab3,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
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

class _StopTimelineRow extends StatelessWidget {
  final Stop stop;
  final bool isFirst;
  final bool isLast;
  final AppColors c;

  /// Minutes to the next stop, from the live fix. Null when there is none.
  final int? nextEtaMinutes;

  /// Running late by this many seconds, used to caption the next stop.
  final int? delaySeconds;

  const _StopTimelineRow({
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.c,
    this.nextEtaMinutes,
    this.delaySeconds,
  });

  /// Secondary line: what already happened, or what is scheduled.
  String get _subtitle {
    switch (stop.state) {
      case StopState.past:
        return stop.scheduledAt == null
            ? 'Departed'
            : 'Departed ${stop.scheduledAt}';
      case StopState.next:
        final delay = delaySeconds ?? 0;
        if (delay > 120) {
          return 'Next stop · ${(delay / 60).round()} min late';
        }
        return 'Next stop · on time';
      case StopState.ahead:
        return stop.scheduledAt == null
            ? 'Scheduled'
            : 'Scheduled ${stop.scheduledAt}';
    }
  }

  /// Trailing value: a live countdown for the next stop, the timetable
  /// otherwise. Only the next stop has a measured ETA, so presenting one for
  /// stops further along would be invented precision.
  String get _trailing {
    if (stop.state == StopState.next) {
      return nextEtaMinutes == null ? '—' : '$nextEtaMinutes min';
    }
    return stop.scheduledAt ?? '—';
  }

  @override
  Widget build(BuildContext context) {
    final past = stop.state == StopState.past;
    final next = stop.state == StopState.next;
    final dotSize = next ? 13.0 : 9.0;
    final railColor = past ? c.lab3 : c.accSoft;
    final dotBg = next ? c.acc : (past ? c.lab3 : c.bgEl);

    return Opacity(
      opacity: past ? 0.42 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 20,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (!isFirst || !isLast)
                      Positioned.fill(
                        top: isFirst ? 10 : 0,
                        bottom: isLast ? 10 : 0,
                        child: Center(
                          child: Container(width: 2, color: railColor),
                        ),
                      ),
                    Container(
                      width: dotSize,
                      height: dotSize,
                      decoration: BoxDecoration(
                        color: dotBg,
                        shape: BoxShape.circle,
                        border: next
                            ? null
                            : (past
                                  ? null
                                  : Border.all(color: c.lab3, width: 2)),
                        boxShadow: next
                            ? [
                                BoxShadow(
                                  color: c.accSoft,
                                  blurRadius: 0,
                                  spreadRadius: 4,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stop.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: next
                          ? sfText(
                              size: 17,
                              weight: FontWeight.w600,
                              letterSpacing: -0.2,
                              color: c.label,
                            )
                          : sfText(
                              size: 15.5,
                              weight: FontWeight.w500,
                              letterSpacing: -0.19,
                              color: c.label,
                            ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _subtitle,
                      style: sfText(
                        size: 12.5,
                        weight: FontWeight.w400,
                        color: c.lab2,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  _trailing,
                  style: next
                      ? sfText(
                          size: 17,
                          weight: FontWeight.w700,
                          letterSpacing: -0.31,
                          color: c.acc,
                        )
                      : sfText(
                          size: 14.5,
                          weight: FontWeight.w500,
                          letterSpacing: -0.26,
                          color: past ? c.lab3 : c.lab2,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
