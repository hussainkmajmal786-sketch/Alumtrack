import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/stop.dart';
import '../theme/color_matrix.dart';

/// OpenStreetMap tiles with an Apple-Maps-style treatment, the route polyline
/// through the real stop coordinates, and the bus at its last known position.
class CampusMap extends StatefulWidget {
  final bool dark;
  final List<Stop> stops;
  final LivePosition? live;

  /// Dims the bus marker when the last fix is too old to trust.
  final bool stale;

  const CampusMap({
    super.key,
    required this.dark,
    required this.stops,
    this.live,
    this.stale = false,
  });

  @override
  State<CampusMap> createState() => CampusMapState();
}

class CampusMapState extends State<CampusMap> {
  final MapController _controller = MapController();

  /// Set once the map has emitted its first event, since fitCamera before
  /// then throws.
  bool _ready = false;

  List<LatLng> get _points => widget.stops.map((s) => s.ll).toList();

  void recenter() {
    if (!_ready || _points.length < 2) return;
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(_points),
        padding: const EdgeInsets.fromLTRB(40, 140, 40, 320),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant CampusMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fit the camera once geometry first arrives; afterwards leave the
    // viewport alone so a poll does not yank the map out from under a pan.
    if (oldWidget.stops.length != widget.stops.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => recenter());
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.dark ? darkMapFilter : lightMapFilter;
    final points = _points;
    final busAt = widget.live?.ll;

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(filter),
      child: FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter: busAt ??
              (points.isNotEmpty ? points.first : const LatLng(9.62, 76.57)),
          initialZoom: 12.2,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onMapReady: () {
            _ready = true;
            recenter();
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.campusbus.campus_bus_tracker',
            tileProvider: NetworkTileProvider(),
          ),
          if (points.length >= 2)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: points,
                  strokeWidth: 4.5,
                  color: const Color(0xFF007AFF),
                ),
              ],
            ),
          MarkerLayer(
            markers: [
              for (final s in widget.stops)
                Marker(
                  point: s.ll,
                  width: 14,
                  height: 14,
                  child: _StopDot(state: s.state),
                ),
              if (busAt != null)
                Marker(
                  point: busAt,
                  width: 34,
                  height: 34,
                  child: _BusMarker(stale: widget.stale),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StopDot extends StatelessWidget {
  final StopState state;
  const _StopDot({required this.state});

  @override
  Widget build(BuildContext context) {
    final past = state == StopState.past;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: past ? const Color(0xFFB9B9C0) : Colors.white,
        border: Border.all(color: const Color(0xFF007AFF), width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
    );
  }
}

class _BusMarker extends StatelessWidget {
  final bool stale;
  const _BusMarker({required this.stale});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: stale ? 0.45 : 1,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF007AFF),
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(color: Color(0x59000000), blurRadius: 10, offset: Offset(0, 3)),
          ],
        ),
        child: const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 18),
      ),
    );
  }
}
