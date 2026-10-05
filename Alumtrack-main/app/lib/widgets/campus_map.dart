import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../data/cached_tile_provider.dart';
import '../data/location_service.dart';
import '../models/stop.dart';
import '../theme/color_matrix.dart';

/// OpenStreetMap tiles with an Apple-Maps-style treatment, the route polyline
/// through the real stop coordinates, and the bus at its last known position.
class CampusMap extends StatefulWidget {
  final bool dark;
  final List<Stop> stops;
  final LivePosition? live;

  /// The real road-follow path through the stops, when the backend has one
  /// cached. Null falls back to a straight line through the stops.
  final List<LatLng>? roadPolyline;

  /// Dims the bus marker when the last fix is too old to trust.
  final bool stale;

  /// Swaps the OSM street tiles for Esri's aerial imagery.
  final bool satellite;

  /// Called when the rider taps a stop marker — the sheet/screen decides
  /// what to show (a detail card, scrolling the stop list to it, etc).
  final void Function(Stop stop)? onStopTap;

  /// Fires whenever follow-mode or heading-up rotation change — including
  /// when a manual gesture silently breaks follow — so a parent showing its
  /// own control buttons (active/inactive state) can stay in sync without
  /// polling `CampusMapState` on every build.
  final void Function(bool following, bool headingUp)? onFollowStateChanged;

  /// Fires once, the first time the rider's own location fix arrives — a
  /// parent's "My Location" button can use this to flip from disabled to
  /// tappable without polling `hasMyLocation` every build.
  final VoidCallback? onMyLocationAvailable;

  const CampusMap({
    super.key,
    required this.dark,
    required this.stops,
    this.live,
    this.roadPolyline,
    this.stale = false,
    this.satellite = false,
    this.onStopTap,
    this.onFollowStateChanged,
    this.onMyLocationAvailable,
  });

  @override
  State<CampusMap> createState() => CampusMapState();
}

class CampusMapState extends State<CampusMap> with TickerProviderStateMixin {
  final MapController _controller = MapController();

  /// Set once the map has emitted its first event, since fitCamera before
  /// then throws.
  bool _ready = false;

  // --- Bus position/heading animation ---------------------------------
  //
  // A live fix lands as a discrete update (poll or subscription push), but
  // riders should see the bus glide rather than teleport. `_busTween`
  // interpolates from wherever the marker currently sits to the new fix;
  // driving it from the *live* interpolated value (not the animation's
  // start point) on every retarget is what makes a fix arriving mid-flight
  // redirect smoothly instead of snapping back to start first.
  late final AnimationController _busAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  Tween<double>? _latTween;
  Tween<double>? _lngTween;
  Tween<double>? _headingTween;
  LatLng? _renderedBusLl;
  double _renderedHeadingDeg = 0;

  // --- Weak-signal pulse -------------------------------------------------
  late final AnimationController _pulseAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  // --- User's own location ------------------------------------------------
  final LocationService _myLocation = LocationService();
  LatLng? _myLl;
  double? _myHeadingDeg;

  // --- Follow mode / heading-up rotation ---------------------------------
  //
  // Google Maps' nav-mode pattern: while following, the camera tracks the
  // bus and (optionally) rotates so its heading is "up". A manual pan/zoom
  // breaks follow — dragging the map out from under someone mid-track reads
  // as broken, not helpful — and only the explicit recenter button resumes
  // it, matching Maps' own re-engage gesture.
  bool _following = false;
  bool _headingUp = false;

  /// Drives the glide for discrete camera moves; replaced (and disposed) on
  /// each new move so a rapid double-tap of a control cannot leave two
  /// animations fighting over the camera.
  AnimationController? _cameraAnim;

  /// Zoom at or above which stop names render beside their dots. Below it
  /// the labels would collide into an unreadable pile, so only the dots
  /// show — the same density trade Maps makes with place labels.
  static const double _stopLabelMinZoom = 14.5;
  bool _showStopLabels = false;

  List<LatLng> get _points => widget.stops.map((s) => s.ll).toList();

  /// The line actually drawn on the map: the real road path when the
  /// backend has fetched one, otherwise the straight line through stops.
  List<LatLng> get _routeLine {
    final road = widget.roadPolyline;
    if (road != null && road.length >= 2) return road;
    return _points;
  }

  /// Splits [_routeLine] at the bus's current progress, so the ground
  /// already covered can be drawn dimmed and the road ahead bright — the
  /// route doubling as a progress bar.
  ///
  /// Progress is a fraction of total *distance*, not of the point count, so
  /// this walks cumulative segment lengths rather than simply slicing the
  /// list: on a road polyline the points bunch up around curves, and
  /// index-slicing would show the split racing ahead through bends and
  /// stalling on straights.
  ({List<LatLng> travelled, List<LatLng> ahead}) _splitRouteAtProgress() {
    final line = _routeLine;
    final progress = widget.live?.progress;
    if (line.length < 2 || progress == null || progress <= 0) {
      return (travelled: const [], ahead: line);
    }
    if (progress >= 1) return (travelled: line, ahead: const []);

    const distance = Distance();
    final segmentLengths = <double>[];
    var total = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      final len = distance(line[i], line[i + 1]);
      segmentLengths.add(len);
      total += len;
    }
    if (total == 0) return (travelled: const [], ahead: line);

    final target = total * progress;
    var walked = 0.0;
    for (var i = 0; i < segmentLengths.length; i++) {
      final next = walked + segmentLengths[i];
      if (next >= target) {
        // Interpolate within this segment so the split lands exactly on the
        // bus rather than snapping to the nearest polyline vertex.
        final t = segmentLengths[i] == 0 ? 0.0 : (target - walked) / segmentLengths[i];
        final a = line[i];
        final b = line[i + 1];
        final split = LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
        return (
          travelled: [...line.sublist(0, i + 1), split],
          ahead: [split, ...line.sublist(i + 1)],
        );
      }
      walked = next;
    }
    return (travelled: line, ahead: const []);
  }

  void _notifyFollowState() {
    widget.onFollowStateChanged?.call(_following, _headingUp);
  }

  /// Glides the camera to a target instead of teleporting, the way Maps
  /// animates every camera change.
  ///
  /// Only for discrete, user-triggered moves (the recenter / follow /
  /// my-location buttons). Follow mode's per-frame tracking deliberately
  /// keeps using a direct `move`: it is already being driven by the bus
  /// marker's own 800ms tween, and layering a second animation on top of
  /// that would fight it, producing a laggy rubber-banding camera.
  void _animateCameraTo(LatLng target, double zoom) {
    final startCenter = _controller.camera.center;
    final startZoom = _controller.camera.zoom;

    _cameraAnim?.dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _cameraAnim = controller;

    final curve = CurvedAnimation(parent: controller, curve: Curves.easeOutCubic);
    controller.addListener(() {
      final t = curve.value;
      _controller.move(
        LatLng(
          startCenter.latitude + (target.latitude - startCenter.latitude) * t,
          startCenter.longitude + (target.longitude - startCenter.longitude) * t,
        ),
        startZoom + (zoom - startZoom) * t,
      );
    });
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        controller.dispose();
        if (identical(_cameraAnim, controller)) _cameraAnim = null;
      }
    });
    controller.forward();
  }

  void recenter() {
    if (!_ready || _points.length < 2) return;
    _following = false;
    _notifyFollowState();
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(_points),
        padding: const EdgeInsets.fromLTRB(40, 140, 40, 320),
      ),
    );
  }

  /// Locks the camera onto the bus, Maps-nav-mode style: subsequent fixes
  /// pan the camera to follow (see `didUpdateWidget`), and — if
  /// [_headingUp] is on — the whole map rotates to keep the bus's travel
  /// direction pointing up rather than just rotating the marker icon.
  void enterFollowMode() {
    if (!_ready) return;
    final at = _renderedBusLl ?? widget.live?.ll;
    if (at == null) return;
    setState(() => _following = true);
    _notifyFollowState();
    _animateCameraTo(at, math.max(_controller.camera.zoom, 15.5));
    if (_headingUp) _rotateToHeading(_renderedHeadingDeg);
  }

  /// Toggles heading-up rotation. Turning it off snaps the map back to
  /// north-up immediately, matching Maps' own compass-button behaviour.
  void toggleHeadingUp() {
    setState(() => _headingUp = !_headingUp);
    _notifyFollowState();
    if (_headingUp && _following) {
      _rotateToHeading(_renderedHeadingDeg);
    } else {
      _controller.rotate(0);
    }
  }

  bool get isFollowing => _following;
  bool get isHeadingUp => _headingUp;

  /// True once a location fix for the rider's own "you are here" dot has
  /// arrived — the recenter-on-me button stays disabled until then, the
  /// same way Maps' own location button is inert before a fix exists.
  bool get hasMyLocation => _myLl != null;

  /// Jumps the camera to the rider's own position, Maps' "My Location"
  /// button pattern. Distinct from [enterFollowMode] — recentering on
  /// yourself and following the bus are two different camera targets, so
  /// engaging one turns the other off rather than fighting over the camera.
  void recenterOnMyLocation() {
    final at = _myLl;
    if (!_ready || at == null) return;
    if (_following) {
      setState(() => _following = false);
      _notifyFollowState();
    }
    _animateCameraTo(at, math.max(_controller.camera.zoom, 16.0));
  }

  void _rotateToHeading(double headingDeg) {
    // flutter_map rotates the camera counter-clockwise for a positive angle,
    // the opposite convention from compass heading, hence the negation.
    _controller.rotate(-headingDeg);
  }

  /// Speed-based zoom, the way Maps pulls the camera out at highway speed
  /// and in when crawling or stopped — purely a suggestion, only applied
  /// while actively following, never fighting a rider's manual zoom.
  double _zoomForSpeed(double? speedKph) {
    final kph = speedKph ?? 0;
    if (kph < 5) return 16.5;
    if (kph < 20) return 15.5;
    if (kph < 40) return 14.5;
    return 13.5;
  }

  @override
  void initState() {
    super.initState();
    _renderedBusLl = widget.live?.ll;
    _renderedHeadingDeg = widget.live?.headingDeg ?? 0;
    _busAnim.addListener(() {
      final latT = _latTween;
      final lngT = _lngTween;
      final headT = _headingTween;
      if (latT == null || lngT == null) return;
      setState(() {
        _renderedBusLl = LatLng(
          latT.transform(_busAnim.value),
          lngT.transform(_busAnim.value),
        );
        if (headT != null) {
          _renderedHeadingDeg = headT.transform(_busAnim.value);
        }
      });
      // Move the camera on every animation tick, not just once per fix, so
      // it glides in step with the marker instead of jumping ahead of it.
      if (_following && _renderedBusLl != null) {
        final zoom = _zoomForSpeed(widget.live?.speedKph);
        _controller.move(_renderedBusLl!, zoom);
        if (_headingUp) _rotateToHeading(_renderedHeadingDeg);
      }
    });
    _startMyLocation();
  }

  Future<void> _startMyLocation() async {
    try {
      await _myLocation.ensurePermission();
      // A passive display dot, independent of rider-assisted sharing: the
      // sharing toggle in AppState starts its own stream and posts fixes to
      // the server, but the "you are here" dot should work (and keep
      // working) regardless of whether the rider ever opts into sharing.
      await _myLocation.start((Position p) {
        if (!mounted) return;
        final hadFixBefore = _myLl != null;
        setState(() {
          _myLl = LatLng(p.latitude, p.longitude);
          _myHeadingDeg = p.heading.isNaN ? null : p.heading;
        });
        if (!hadFixBefore) widget.onMyLocationAvailable?.call();
      });
    } on LocationException {
      // Silently skip the dot if permission is refused — this is a nicety,
      // not a feature the rider explicitly asked for, so it should never
      // interrupt them with an error.
    }
  }

  @override
  void didUpdateWidget(covariant CampusMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fit the camera once geometry first arrives; afterwards leave the
    // viewport alone so a poll does not yank the map out from under a pan.
    if (oldWidget.stops.length != widget.stops.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => recenter());
    }

    final newLl = widget.live?.ll;
    if (newLl != null && newLl != oldWidget.live?.ll) {
      final from = _renderedBusLl ?? newLl;
      final fromHeading = _renderedHeadingDeg;
      final toHeading = widget.live?.headingDeg ?? fromHeading;
      _latTween = Tween(begin: from.latitude, end: newLl.latitude);
      _lngTween = Tween(begin: from.longitude, end: newLl.longitude);
      _headingTween = Tween(
        begin: fromHeading,
        end: _shortestHeading(fromHeading, toHeading),
      );
      _busAnim
        ..stop()
        ..reset()
        ..forward();
    } else if (_renderedBusLl == null && newLl != null) {
      _renderedBusLl = newLl;
      _renderedHeadingDeg = widget.live?.headingDeg ?? 0;
    }
  }

  /// Picks the equivalent target angle closest to `from`, so a heading tween
  /// crossing the 0/360 boundary (e.g. 350deg -> 10deg) turns the short way
  /// instead of spinning the marker almost all the way around.
  double _shortestHeading(double from, double to) {
    final delta = ((to - from + 180) % 360 + 360) % 360 - 180;
    return from + delta;
  }

  @override
  void dispose() {
    _busAnim.dispose();
    _pulseAnim.dispose();
    _cameraAnim?.dispose();
    unawaited(_myLocation.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The dark-mode treatment inverts and desaturates the tiles, which is
    // right for a drawn street map but wrong for photography — inverted
    // aerial imagery reads as a negative. Satellite therefore renders
    // unfiltered in both themes.
    final filter = widget.satellite
        ? null
        : (widget.dark ? darkMapFilter : lightMapFilter);
    final points = _points;
    final busAt = _renderedBusLl;
    final weak = widget.live != null && (widget.stale || _isWeak(widget.live));

    final map = FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter: busAt ??
              (points.isNotEmpty ? points.first : const LatLng(9.62, 76.57)),
          initialZoom: 12.2,
          // Rotation is on so heading-up follow mode can actually spin the
          // map; a raw two-finger twist gesture is intentionally still
          // allowed (Maps permits it too) but any manual gesture — twist
          // included — breaks follow, so it never fights a rider's touch.
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
          onMapReady: () {
            _ready = true;
            recenter();
          },
          onPositionChanged: (position, hasGesture) {
            if (hasGesture && _following) {
              setState(() => _following = false);
              _notifyFollowState();
            }
            // Stop labels only appear once zoomed in far enough that they
            // will not overlap each other into an unreadable pile.
            final showLabels = position.zoom >= _stopLabelMinZoom;
            if (showLabels != _showStopLabels) {
              setState(() => _showStopLabels = showLabels);
            }
          },
        ),
        children: [
          TileLayer(
            // Esri's tile path is {z}/{y}/{x} — row before column, the
            // reverse of the OSM/XYZ convention — so the two templates are
            // not interchangeable beyond swapping the host.
            urlTemplate: widget.satellite
                ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            // Imagery over this route runs out after z18; without this the
            // map would show blank tiles when zoomed in further rather
            // than upscaling the last real level.
            maxNativeZoom: widget.satellite ? 18 : 19,
            userAgentPackageName: 'com.campusbus.campus_bus_tracker',
            // Web has no filesystem to cache tiles onto (and the browser's
            // own HTTP cache already covers the same case there), so the
            // on-disk cache is mobile-only.
            tileProvider: kIsWeb ? NetworkTileProvider() : CachedTileProvider(),
          ),
          if (_routeLine.length >= 2)
            Builder(
              builder: (context) {
                final split = _splitRouteAtProgress();
                return PolylineLayer(
                  polylines: [
                    // Ground already covered, dimmed — drawn first so the
                    // road ahead paints over it at the join.
                    if (split.travelled.length >= 2)
                      Polyline(
                        points: split.travelled,
                        strokeWidth: 4.5,
                        color: const Color(0xFF007AFF).withValues(alpha: 0.28),
                      ),
                    if (split.ahead.length >= 2)
                      Polyline(
                        points: split.ahead,
                        strokeWidth: 4.5,
                        color: const Color(0xFF007AFF),
                      ),
                  ],
                );
              },
            ),
          if (busAt != null && weak)
            CircleLayer(
              circles: [
                CircleMarker(
                  point: busAt,
                  useRadiusInMeter: true,
                  radius: _confidenceRadiusM(widget.live),
                  color: const Color(0x22FF9F0A),
                  borderColor: const Color(0x55FF9F0A),
                  borderStrokeWidth: 1.5,
                ),
              ],
            ),
          if (widget.stops.isNotEmpty)
            MarkerClusterLayerWidget(
              options: MarkerClusterLayerOptions(
                // Stops on a short campus shuttle route rarely overlap, so
                // clustering only kicks in when several are genuinely close
                // together at a given zoom — the same "collapse into a
                // count badge, split apart on zoom-in" pattern Maps uses
                // for dense pin clusters, rather than a hard requirement
                // here.
                maxClusterRadius: 45,
                size: const Size(34, 34),
                disableClusteringAtZoom: 17,
                zoomToBoundsOnClick: true,
                markers: [
                  for (final s in widget.stops)
                    Marker(
                      point: s.ll,
                      // A wider tappable area than the visible 14px dot — a
                      // raw 14px hit target is well under the ~44dp minimum
                      // touch target both Apple's and Google's guidelines
                      // call for. Widens further when the label is showing
                      // so the name has room without being clipped.
                      width: _showStopLabels ? 130 : 40,
                      height: _showStopLabels ? 58 : 40,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onStopTap == null ? null : () => widget.onStopTap!(s),
                        child: _showStopLabels
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // Explicit size: outside a Center the dot's
                                  // own Container has no intrinsic dimensions
                                  // and would collapse to nothing in a Column.
                                  SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: _StopDot(state: s.state),
                                  ),
                                  const SizedBox(height: 3),
                                  _StopLabel(name: s.name, past: s.state == StopState.past),
                                ],
                              )
                            : Center(child: _StopDot(state: s.state)),
                      ),
                    ),
                ],
                builder: (context, markers) => _ClusterBadge(count: markers.length),
              ),
            ),
          MarkerLayer(
            markers: [
              if (_myLl != null)
                Marker(
                  point: _myLl!,
                  width: 22,
                  height: 22,
                  child: _MyLocationDot(headingDeg: _myHeadingDeg),
                ),
              if (busAt != null)
                Marker(
                  point: busAt,
                  width: 34,
                  height: 34,
                  child: AnimatedBuilder(
                    animation: _pulseAnim,
                    builder: (context, _) => _BusMarker(
                      headingDeg: _renderedHeadingDeg,
                      weak: weak,
                      moving: (widget.live?.speedKph ?? 0) >= 4.0,
                      pulse: _pulseAnim.value,
                    ),
                  ),
                ),
            ],
          ),
          // A live "500 m"-style ruler, Maps' own scale indicator pattern —
          // ships with flutter_map itself, so no extra dependency needed.
          Scalebar(
            alignment: Alignment.bottomLeft,
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 130),
            textStyle: const TextStyle(
              color: Color(0xFF3C3C43),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            lineColor: const Color(0xFF3C3C43),
            strokeWidth: 2,
            lineHeight: 4,
          ),
          // Esri's imagery is free to use but requires the source credit be
          // shown, so this is a licence condition rather than decoration.
          if (widget.satellite)
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomRight,
              attributions: [
                TextSourceAttribution(
                  'Esri, Vantor, Earthstar Geographics',
                  prependCopyright: false,
                ),
              ],
            ),
        ],
      );

    if (filter == null) return map;
    return ColorFiltered(colorFilter: ColorFilter.matrix(filter), child: map);
  }

  bool _isWeak(LivePosition? live) {
    if (live == null) return false;
    if (live.source == 'rider') return true;
    if (live.accuracyM != null && live.accuracyM! > 75) return true;
    return false;
  }

  double _confidenceRadiusM(LivePosition? live) {
    final a = live?.accuracyM;
    if (a == null || a <= 0) return 60;
    return a.clamp(30, 250);
  }
}

/// The count badge a cluster of nearby stops collapses into — Maps' own
/// pattern for a busy pin area, split apart again by tapping (which zooms
/// in, per `zoomToBoundsOnClick`) or by zooming in manually.
class _ClusterBadge extends StatelessWidget {
  final int count;
  const _ClusterBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF007AFF),
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [
          BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
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

/// A stop's name rendered beside its dot at close zoom.
///
/// Given a white pill background rather than bare text: map tiles vary from
/// pale road fill to dark green parkland underneath, and unbacked text
/// becomes unreadable over the darker patches.
class _StopLabel extends StatelessWidget {
  final String name;
  final bool past;
  const _StopLabel({required this.name, required this.past});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(color: Color(0x26000000), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: past ? const Color(0xFF8E8E93) : const Color(0xFF1C1C1E),
        ),
      ),
    );
  }
}

class _MyLocationDot extends StatelessWidget {
  final double? headingDeg;
  const _MyLocationDot({this.headingDeg});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0x332D9BF0),
          ),
        ),
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF2D9BF0),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1)),
            ],
          ),
        ),
      ],
    );
  }
}

class _BusMarker extends StatelessWidget {
  /// Direction of travel in degrees, 0 = north. Null when unknown, in which
  /// case the icon renders unrotated rather than guessing.
  final double headingDeg;
  final bool weak;

  /// Whether the bus is actually driving right now, which adds a quiet
  /// expanding ring beneath the marker — a visual heartbeat that the feed
  /// is live and the vehicle is in motion. Deliberately distinct from the
  /// amber [weak] pulse: that one signals a problem, this one signals
  /// everything is working.
  final bool moving;

  /// 0..1 pulse phase, driven by the map's repeating pulse animation.
  final double pulse;

  const _BusMarker({
    required this.headingDeg,
    required this.weak,
    required this.moving,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    final color = weak ? const Color(0xFFFF9F0A) : const Color(0xFF007AFF);
    // Solid when signal is good; a slow amber breathe when it is weak, so
    // degraded tracking is visible on the marker itself, not just in copy
    // elsewhere on screen.
    final opacity = weak ? 0.55 + 0.45 * pulse : 1.0;
    final ringScale = weak ? 1.0 + 0.18 * pulse : 1.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        // A ground-contact shadow near the bottom edge of the marker's own
        // bounds reads as the pin floating above the flat tile plane — the
        // closest honest approximation of Apple Maps' tilted 3D pins
        // available without switching to a vector map engine that supports
        // real camera tilt.
        Positioned(
          bottom: 0,
          child: Container(
            width: 18,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.20),
            ),
          ),
        ),
        if (weak)
          Transform.scale(
            scale: ringScale,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.25 * (1 - pulse)),
              ),
            ),
          )
        // Only when the signal is healthy: a weak fix already has its own
        // amber pulse, and stacking two rings would just read as noise.
        else if (moving)
          Transform.scale(
            scale: 1.0 + 0.34 * pulse,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.22 * (1 - pulse)),
              ),
            ),
          ),
        Opacity(
          opacity: opacity,
          child: Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Color(0x59000000), blurRadius: 10, offset: Offset(0, 3)),
              ],
            ),
            child: Transform.rotate(
              angle: headingDeg * math.pi / 180,
              child: CustomPaint(
                size: const Size(30, 30),
                painter: _BusIconPainter(color: color),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A top-down bus silhouette — body, windshield, and wheel marks — instead
/// of a generic circle-and-arrow, so the marker actually reads as "a bus"
/// at a glance rather than an abstract direction indicator.
///
/// Drawn with [CustomPainter] rather than a raster asset so it stays crisp
/// at any zoom level and tints correctly for the weak-signal amber state
/// without needing a second image asset.
class _BusIconPainter extends CustomPainter {
  final Color color;
  const _BusIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w / 2, h / 2);

    // The body is drawn nose-up (pointing to 0deg/north) since the parent
    // Transform.rotate already applies the live heading on top of this.
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w * 0.62, height: h * 0.86),
      Radius.circular(w * 0.16),
    );

    canvas.drawRRect(
      bodyRect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      bodyRect.deflate(1.4),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );

    // Windshield: a lighter stripe near the front (top) edge.
    final windshieldRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(center.dx, center.dy - h * 0.22),
        width: w * 0.42,
        height: h * 0.14,
      ),
      Radius.circular(w * 0.05),
    );
    canvas.drawRRect(
      windshieldRect,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );

    // Side window band, below the windshield.
    final windowRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(center.dx, center.dy - h * 0.02),
        width: w * 0.46,
        height: h * 0.16,
      ),
      Radius.circular(w * 0.04),
    );
    canvas.drawRRect(
      windowRect,
      Paint()..color = Colors.white.withValues(alpha: 0.55),
    );

    // Wheel marks, one pair front and one pair rear, just outside the body.
    final wheelPaint = Paint()..color = const Color(0xFF1C1C1E);
    final wheelWidth = w * 0.08;
    final wheelHeight = h * 0.16;
    for (final dy in [-h * 0.24, h * 0.24]) {
      for (final dx in [-w * 0.34, w * 0.34]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(center.dx + dx, center.dy + dy),
              width: wheelWidth,
              height: wheelHeight,
            ),
            Radius.circular(wheelWidth * 0.4),
          ),
          wheelPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BusIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
