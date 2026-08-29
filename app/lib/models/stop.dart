import 'package:latlong2/latlong.dart';

enum StopState { past, next, ahead }

class Stop {
  final String name;
  final String sub;
  final String eta;
  final StopState state;
  final LatLng ll;

  const Stop({
    required this.name,
    required this.sub,
    required this.eta,
    required this.state,
    required this.ll,
  });
}

/// Real coordinates: Kottayam KSRTC stand -> College of Engineering Kidangoor.
const List<Stop> routeStops = [
  Stop(name: 'Kottayam KSRTC', sub: 'Departed 9:22', eta: '9:22', state: StopState.past, ll: LatLng(9.5926, 76.5222)),
  Stop(name: 'Malam', sub: 'Departed 9:31', eta: '9:31', state: StopState.past, ll: LatLng(9.6140, 76.5540)),
  Stop(name: 'Oravakal', sub: 'Departed 9:38', eta: '9:38', state: StopState.past, ll: LatLng(9.6265, 76.5695)),
  Stop(name: 'Ayarkunnam', sub: 'Next stop · on time', eta: '6 min', state: StopState.next, ll: LatLng(9.6390, 76.5850)),
  Stop(name: 'Manthadi', sub: 'Scheduled 9:54', eta: '13 min', state: StopState.ahead, ll: LatLng(9.6480, 76.6015)),
  Stop(name: 'Kidangoor Junction', sub: 'Scheduled 10:00', eta: '19 min', state: StopState.ahead, ll: LatLng(9.6600, 76.6175)),
  Stop(name: 'College of Engineering Kidangoor', sub: 'Final stop · 10:05', eta: '24 min', state: StopState.ahead, ll: LatLng(9.6655, 76.6285)),
];

/// Bus progress (0..1) along the route, used to place the map marker —
/// matches the prototype's fixed `progress="0.42"` preview value.
const double busRouteProgress = 0.42;

LatLng pointAtProgress(double progress) {
  final t = progress.clamp(0.0, 1.0) * (routeStops.length - 1);
  final i = t.floor().clamp(0, routeStops.length - 2);
  final f = t - i;
  final a = routeStops[i].ll;
  final b = routeStops[i + 1].ll;
  return LatLng(a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f);
}
