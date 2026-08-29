import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/stop.dart';
import '../theme/color_matrix.dart';

/// Ports `campus-map.js`: Leaflet + OSM tiles, Apple-Maps-style tile
/// treatment (a CSS filter in the prototype, a ColorFiltered layer here),
/// the real Kottayam -> CEK Kidangoor stop coordinates, and a route line
/// with a bus marker placed at [progress] along it.
class CampusMap extends StatefulWidget {
  final bool dark;
  final double progress;
  final MapController? controller;

  const CampusMap({super.key, required this.dark, this.progress = busRouteProgress, this.controller});

  @override
  State<CampusMap> createState() => CampusMapState();
}

class CampusMapState extends State<CampusMap> {
  late final MapController _controller = widget.controller ?? MapController();
  static final LatLng _busPoint = pointAtProgress(busRouteProgress);
  static final LatLngBounds _bounds = LatLngBounds.fromPoints(routeStops.map((s) => s.ll).toList());

  void recenter({bool animate = true}) {
    _controller.fitCamera(CameraFit.bounds(bounds: _bounds, padding: const EdgeInsets.fromLTRB(40, 140, 40, 320)));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => recenter());
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.dark ? darkMapFilter : lightMapFilter;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(filter),
      child: FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter: _busPoint,
          initialZoom: 12.2,
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.campusbus.campus_bus_tracker',
            tileProvider: NetworkTileProvider(),
          ),
          PolylineLayer(
            polylines: [
              Polyline(
                points: routeStops.map((s) => s.ll).toList(),
                strokeWidth: 4.5,
                color: const Color(0xFF007AFF),
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              for (final s in routeStops)
                Marker(
                  point: s.ll,
                  width: 14,
                  height: 14,
                  child: _StopDot(state: s.state),
                ),
              Marker(
                point: _busPoint,
                width: 34,
                height: 34,
                child: const _BusMarker(),
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
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))],
      ),
    );
  }
}

class _BusMarker extends StatelessWidget {
  const _BusMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF007AFF),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 18),
    );
  }
}
