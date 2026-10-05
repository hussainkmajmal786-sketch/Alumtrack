import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Why location sharing could not start, in terms the UI can explain.
enum LocationDenial { serviceDisabled, denied, deniedForever }

class LocationException implements Exception {
  final LocationDenial reason;
  const LocationException(this.reason);

  String get message {
    switch (reason) {
      case LocationDenial.serviceDisabled:
        return 'Turn on location services to help track this bus.';
      case LocationDenial.denied:
        return 'Location permission is needed to share your position.';
      case LocationDenial.deniedForever:
        return 'Location is blocked for this app. Enable it in Settings.';
    }
  }

  /// Only the permanent denial needs the OS settings page.
  bool get needsAppSettings => reason == LocationDenial.deniedForever;
}

/// Foreground location updates for rider-assisted tracking.
///
/// Deliberately foreground-only: sharing stops when the app is backgrounded,
/// which is what the consent copy promises and what keeps the app clear of
/// background-location review requirements on both stores.
class LocationService {
  StreamSubscription<Position>? _subscription;

  bool get isTracking => _subscription != null;

  /// Requests permission, throwing [LocationException] when refused.
  Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationException(LocationDenial.serviceDisabled);
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      throw const LocationException(LocationDenial.deniedForever);
    }
    if (permission == LocationPermission.denied) {
      throw const LocationException(LocationDenial.denied);
    }
  }

  /// Begins streaming fixes to [onFix]. Call [stop] to end the stream.
  Future<void> start(void Function(Position) onFix) async {
    await ensurePermission();
    await stop();

    // 20 m between updates keeps the radio duty cycle low; a bus covers that
    // in about two seconds at road speed, which is plenty for a tracker.
    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20,
    );

    _subscription =
        Geolocator.getPositionStream(locationSettings: settings).listen(onFix);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<bool> openAppSettings() => Geolocator.openAppSettings();
}
