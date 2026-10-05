import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/stop.dart' as models;

/// A genuine 3D map: vector tiles rendered by MapLibre GL, with a tilted
/// camera and extruded buildings.
///
/// This exists alongside [CampusMap] rather than replacing it. The raster
/// map is flat by nature — tilting a stack of pre-rendered images only
/// skews the labels — so real perspective needs a vector engine. MapLibre
/// is BSD-licensed and the tiles come from OpenFreeMap, which needs no API
/// key and no billing account, so nothing here depends on a paid service.
class CampusMap3D extends StatefulWidget {
  final bool dark;
  final List<models.Stop> stops;
  final models.LivePosition? live;

  /// Route geometry in the app's own `latlong2` coordinates. Converted to
  /// MapLibre's identically-named but unrelated `LatLng` inside this widget,
  /// so callers never have to care that two `LatLng` types are in play.
  final List<ll.LatLng>? roadPolyline;
  final bool stale;

  const CampusMap3D({
    super.key,
    required this.dark,
    required this.stops,
    this.live,
    this.roadPolyline,
    this.stale = false,
  });

  @override
  State<CampusMap3D> createState() => CampusMap3DState();
}

class CampusMap3DState extends State<CampusMap3D> {
  MapLibreMapController? _controller;
  bool _styleReady = false;

  /// Camera pitch in degrees. 50 gives a clear sense of depth without
  /// stretching the horizon so far that distant labels become unreadable.
  static const double _tilt = 50;

  static const String _routeSourceId = 'route-src';
  static const String _busSourceId = 'bus-src';
  static const String _stopsSourceId = 'stops-src';

  /// OpenFreeMap's "liberty" style — an OpenMapTiles-schema vector style
  /// that already ships a `building-3d` fill-extrusion layer, so buildings
  /// stand up without us having to author the extrusion ourselves.
  String get _styleUrl => 'https://tiles.openfreemap.org/styles/liberty';

  List<LatLng> get _routeLine {
    final road = widget.roadPolyline;
    if (road != null && road.length >= 2) {
      return [for (final p in road) LatLng(p.latitude, p.longitude)];
    }
    return [for (final s in widget.stops) LatLng(s.ll.latitude, s.ll.longitude)];
  }

  LatLng get _initialTarget {
    final live = widget.live;
    if (live != null) return LatLng(live.ll.latitude, live.ll.longitude);
    final line = _routeLine;
    if (line.isNotEmpty) return line.first;
    return const LatLng(9.62, 76.57);
  }

  @override
  void didUpdateWidget(covariant CampusMap3D oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_styleReady) return;
    if (oldWidget.live?.ll != widget.live?.ll) unawaited(_updateBus());
    if (oldWidget.roadPolyline != widget.roadPolyline ||
        oldWidget.stops.length != widget.stops.length) {
      unawaited(_updateRoute());
      unawaited(_updateStops());
    }
  }

  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;

    // Sources are seeded empty and then fed by the update methods, so the
    // same code path handles first paint and every later refresh — no
    // separate "create vs update" branches to drift apart.
    await c.addGeoJsonSource(_routeSourceId, _emptyFeatureCollection());
    await c.addGeoJsonSource(_stopsSourceId, _emptyFeatureCollection());
    await c.addGeoJsonSource(_busSourceId, _emptyFeatureCollection());

    // The travelled/remaining split the 2D map draws is deliberately not
    // reproduced here: on a tilted camera the join sits at a different
    // apparent position depending on pitch, which reads as a rendering
    // glitch rather than progress. A single clear line is more honest in
    // perspective.
    await c.addLineLayer(
      _routeSourceId,
      'route-line',
      const LineLayerProperties(
        lineColor: '#007AFF',
        lineWidth: 5.0,
        lineOpacity: 0.9,
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );

    await c.addCircleLayer(
      _stopsSourceId,
      'stops-circles',
      const CircleLayerProperties(
        circleRadius: 6.0,
        circleColor: '#FFFFFF',
        circleStrokeColor: '#007AFF',
        circleStrokeWidth: 2.5,
        circlePitchAlignment: 'map',
      ),
    );

    await c.addSymbolLayer(
      _stopsSourceId,
      'stops-labels',
      const SymbolLayerProperties(
        textField: [Expressions.get, 'name'],
        textSize: 11.0,
        textOffset: [0, 1.4],
        textAnchor: 'top',
        textColor: '#1C1C1E',
        textHaloColor: '#FFFFFF',
        textHaloWidth: 1.4,
        // Labels stay upright and screen-aligned rather than lying flat on
        // the tilted ground plane, which would make them unreadable.
        textPitchAlignment: 'viewport',
        textAllowOverlap: false,
      ),
      minzoom: 13,
    );

    // Drawn last so the bus sits above the route line and stop dots.
    await c.addCircleLayer(
      _busSourceId,
      'bus-dot',
      const CircleLayerProperties(
        circleRadius: 9.0,
        circleColor: '#007AFF',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3.0,
        circlePitchAlignment: 'map',
      ),
    );

    _styleReady = true;
    await _updateRoute();
    await _updateStops();
    await _updateBus();
    await _fitToRoute();
  }

  Map<String, dynamic> _emptyFeatureCollection() => {
        'type': 'FeatureCollection',
        'features': <dynamic>[],
      };

  Future<void> _updateRoute() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final line = _routeLine;
    if (line.length < 2) return;
    await c.setGeoJsonSource(_routeSourceId, {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': <String, dynamic>{},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final p in line) [p.longitude, p.latitude],
            ],
          },
        },
      ],
    });
  }

  Future<void> _updateStops() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    await c.setGeoJsonSource(_stopsSourceId, {
      'type': 'FeatureCollection',
      'features': [
        for (final s in widget.stops)
          {
            'type': 'Feature',
            'properties': {'name': s.name},
            'geometry': {
              'type': 'Point',
              'coordinates': [s.ll.longitude, s.ll.latitude],
            },
          },
      ],
    });
  }

  Future<void> _updateBus() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final live = widget.live;
    if (live == null) {
      await c.setGeoJsonSource(_busSourceId, _emptyFeatureCollection());
      return;
    }
    await c.setGeoJsonSource(_busSourceId, {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': <String, dynamic>{},
          'geometry': {
            'type': 'Point',
            'coordinates': [live.ll.longitude, live.ll.latitude],
          },
        },
      ],
    });
  }

  Future<void> _fitToRoute() async {
    final c = _controller;
    final line = _routeLine;
    if (c == null || line.length < 2) return;
    var minLat = line.first.latitude, maxLat = line.first.latitude;
    var minLng = line.first.longitude, maxLng = line.first.longitude;
    for (final p in line) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    await c.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        left: 40,
        right: 40,
        top: 140,
        bottom: 320,
      ),
    );
  }

  /// Frames the bus close-in with the camera pitched over, the view that
  /// actually shows off the 3D buildings.
  Future<void> followBus() async {
    final c = _controller;
    final live = widget.live;
    if (c == null || live == null) return;
    await c.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(live.ll.latitude, live.ll.longitude),
          zoom: 17,
          tilt: _tilt,
          bearing: live.headingDeg ?? 0,
        ),
      ),
    );
  }

  Future<void> resetView() => _fitToRoute();

  @override
  Widget build(BuildContext context) {
    return MapLibreMap(
      styleString: _styleUrl,
      initialCameraPosition: CameraPosition(
        target: _initialTarget,
        zoom: 15,
        tilt: _tilt,
      ),
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
      compassEnabled: true,
      myLocationEnabled: false,
      trackCameraPosition: true,
      onMapCreated: (c) => _controller = c,
      onStyleLoadedCallback: () => unawaited(_onStyleLoaded()),
    );
  }
}
