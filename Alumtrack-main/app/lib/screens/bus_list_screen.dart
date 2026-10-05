import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../models/bus.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class BusListScreen extends StatefulWidget {
  const BusListScreen({super.key});

  @override
  State<BusListScreen> createState() => _BusListScreenState();
}

class _BusListScreenState extends State<BusListScreen> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _searchController = TextEditingController(text: state.query);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;
    final buses = state.visibleBuses;

    return Container(
      color: c.bg,
      child: SafeArea(
        child: RefreshIndicator(
          color: c.acc,
          onRefresh: state.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Buses', style: sfText(size: 34, weight: FontWeight.w700, letterSpacing: -0.95, color: c.label)),
                          const SizedBox(height: 5),
                          Text(
                            'Updated ${state.updated} · '
                            '${state.buses.length} '
                            '${state.buses.length == 1 ? 'route' : 'routes'}',
                            style: sfText(size: 13, weight: FontWeight.w400, color: c.lab2),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(19),
                        onTap: state.goSettings,
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(color: c.fill, shape: BoxShape.circle),
                          child: Icon(Icons.settings_outlined, size: 19, color: c.label),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(11)),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 18, color: c.lab2),
                      const SizedBox(width: 7),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: state.setQuery,
                          style: sfText(size: 16, weight: FontWeight.w400, color: c.label),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Route number or stop',
                            hintStyle: sfText(size: 16, weight: FontWeight.w400, color: c.lab3),
                          ),
                        ),
                      ),
                      if (state.query.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            state.setQuery('');
                          },
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(color: c.lab3, shape: BoxShape.circle),
                            child: Icon(Icons.close, size: 10, color: c.bgEl),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (state.query.trim().isEmpty && state.recentBuses.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                        child: Text(
                          'RECENT',
                          style: sfText(
                            size: 12,
                            weight: FontWeight.w600,
                            letterSpacing: 0.6,
                            color: c.lab2,
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: c.bgEl,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: c.shadow,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            for (var i = 0; i < state.recentBuses.length; i++)
                              _BusRow(
                                bus: state.recentBuses[i],
                                showSeparator: i != state.recentBuses.length - 1,
                                onTap: () => state.openBus(state.recentBuses[i].id),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (state.listState == Loadable.loading && buses.isEmpty)
                _ListPlaceholder(c: c)
              else if (state.listState == Loadable.failed && buses.isEmpty)
                _ListError(
                  message: state.listError ?? 'Could not load routes.',
                  canRetry: state.listErrorRetryable,
                  onRetry: () => state.refreshList(),
                  c: c,
                )
              else if (buses.isEmpty)
                _ListEmpty(hasQuery: state.query.trim().isNotEmpty, c: c)
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.bgEl,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: c.shadow,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < buses.length; i++)
                          _BusRow(
                            bus: buses[i],
                            showSeparator: i != buses.length - 1,
                            onTap: () => state.openBus(buses[i].id),
                          ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                child: Text(
                  'Pull down to refresh. Arrival times come from onboard GPS and, where enabled, from riders sharing location.',
                  style: sfText(size: 12.5, weight: FontWeight.w400, color: c.lab3, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton rows while the first load is in flight.
class _ListPlaceholder extends StatelessWidget {
  final AppColors c;
  const _ListPlaceholder({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: c.bgEl,
          borderRadius: BorderRadius.circular(18),
          boxShadow: c.shadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: List.generate(
            5,
            (i) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: c.fill,
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(height: 14, width: 180, color: c.fill),
                        const SizedBox(height: 8),
                        Container(height: 12, width: 90, color: c.fill),
                      ],
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

class _ListError extends StatelessWidget {
  final String message;
  final bool canRetry;
  final VoidCallback onRetry;
  final AppColors c;

  const _ListError({
    required this.message,
    required this.canRetry,
    required this.onRetry,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 0),
      child: Column(
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

class _ListEmpty extends StatelessWidget {
  final bool hasQuery;
  final AppColors c;
  const _ListEmpty({required this.hasQuery, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 0),
      child: Column(
        children: [
          Icon(
            hasQuery ? Icons.search_off_rounded : Icons.directions_bus_outlined,
            size: 40,
            color: c.lab3,
          ),
          const SizedBox(height: 16),
          Text(
            hasQuery ? 'No routes match that search.' : 'No routes are running yet.',
            textAlign: TextAlign.center,
            style: sfText(size: 15, weight: FontWeight.w500, color: c.label, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// A small, non-interactive path preview — Maps' place-card thumbnail
/// pattern. Deliberately not a real tiny map (no tiles, no controller): a
/// row of these renders on every list frame, and a live `flutter_map`
/// instance per row would be needless overhead for something this small.
/// Just the route's shape, scaled to fit.
class _RoutePreviewThumbnail extends StatelessWidget {
  final List<LatLng> points;
  final AppColors c;
  const _RoutePreviewThumbnail({required this.points, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(13)),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _RoutePathPainter(points: points, color: c.acc),
      ),
    );
  }
}

class _RoutePathPainter extends CustomPainter {
  final List<LatLng> points;
  final Color color;
  const _RoutePathPainter({required this.points, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    // Project lat/lng to the box with equal x/y scale (using cos(latitude)
    // for the x scale) so the path's shape isn't stretched, then fit it
    // inside the box with a small margin.
    final latRef = points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
    final xScale = math.cos(latRef * math.pi / 180);

    final projected = points
        .map((p) => Offset(p.longitude * xScale, -p.latitude))
        .toList();

    var minX = projected.first.dx, maxX = projected.first.dx;
    var minY = projected.first.dy, maxY = projected.first.dy;
    for (final p in projected) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final spanX = maxX - minX;
    final spanY = maxY - minY;
    // A route that is a single point in one axis (e.g. runs due
    // north-south) would otherwise divide by zero when fitting that axis.
    final span = math.max(spanX, spanY);
    if (span == 0) return;

    const margin = 9.0;
    final scale = (math.min(size.width, size.height) - margin * 2) / span;
    final centerX = (minX + maxX) / 2;
    final centerY = (minY + maxY) / 2;
    final boxCenter = Offset(size.width / 2, size.height / 2);

    Offset toCanvas(Offset p) =>
        boxCenter + Offset((p.dx - centerX) * scale, (p.dy - centerY) * scale);

    final path = Path()..moveTo(toCanvas(projected.first).dx, toCanvas(projected.first).dy);
    for (final p in projected.skip(1)) {
      final c = toCanvas(p);
      path.lineTo(c.dx, c.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final endPaint = Paint()..color = color;
    canvas.drawCircle(toCanvas(projected.first), 2.5, endPaint);
    canvas.drawCircle(toCanvas(projected.last), 2.5, endPaint);
  }

  @override
  bool shouldRepaint(covariant _RoutePathPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

class _BusRow extends StatelessWidget {
  final Bus bus;
  final bool showSeparator;
  final VoidCallback onTap;

  const _BusRow({required this.bus, required this.showSeparator, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    final Color pillBg;
    final Color pillFg;
    final IconData icon;
    switch (bus.status) {
      case BusStatus.onTime:
        pillBg = c.greenBg;
        pillFg = c.green;
        icon = Icons.check_rounded;
        break;
      case BusStatus.late:
        pillBg = c.orangeBg;
        pillFg = c.orange;
        icon = Icons.schedule_rounded;
        break;
      case BusStatus.weak:
        pillBg = c.orangeBg;
        pillFg = c.orange;
        icon = Icons.wifi_off_rounded;
        break;
      case BusStatus.off:
        pillBg = c.grayBg;
        pillFg = c.gray;
        icon = Icons.block_rounded;
        break;
    }
    final etaColor = bus.status == BusStatus.off ? c.lab3 : bus.status == BusStatus.onTime ? c.label : c.lab2;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(13)),
                    alignment: Alignment.center,
                    child: Text(bus.no, style: sfText(size: 17, weight: FontWeight.w700, letterSpacing: -0.34, color: c.label)),
                  ),
                  if (bus.previewPoints.length >= 2) ...[
                    const SizedBox(width: 10),
                    _RoutePreviewThumbnail(points: bus.previewPoints, c: c),
                  ],
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        routeLabel(
                          bus.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sfText(size: 16, weight: FontWeight.w600, letterSpacing: -0.19, color: c.label),
                        ),
                        const SizedBox(height: 5),
                        Container(
                          padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
                          decoration: BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(7)),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, size: 12, color: pillFg),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  bus.statusLabel,
                                  overflow: TextOverflow.ellipsis,
                                  style: sfText(size: 11.5, weight: FontWeight.w600, color: pillFg),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(bus.eta, style: sfText(size: 15, weight: FontWeight.w600, letterSpacing: -0.3, color: etaColor)),
                      const SizedBox(height: 4),
                      Icon(Icons.chevron_right_rounded, size: 16, color: c.lab3),
                    ],
                  ),
                ],
              ),
            ),
            if (showSeparator)
              Positioned(
                left: 75,
                right: 0,
                bottom: 0,
                child: Container(height: 1, color: c.sep),
              ),
          ],
        ),
      ),
    );
  }
}
