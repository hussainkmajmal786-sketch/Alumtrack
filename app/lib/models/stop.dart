import 'package:latlong2/latlong.dart';

enum StopState { past, next, ahead }

StopState stopStateFromApi(String? raw) {
  switch (raw) {
    case 'past':
      return StopState.past;
    case 'next':
      return StopState.next;
    default:
      return StopState.ahead;
  }
}

class Stop {
  final int seq;
  final String name;
  final LatLng ll;
  final StopState state;

  /// Scheduled clock time at this stop, "HH:mm", when the route has a timetable.
  final String? scheduledAt;

  const Stop({
    required this.seq,
    required this.name,
    required this.ll,
    required this.state,
    this.scheduledAt,
  });

  factory Stop.fromJson(Map<String, dynamic> json) => Stop(
        seq: (json['seq'] as num).toInt(),
        name: json['name'] as String,
        ll: LatLng(
          (json['lat'] as num).toDouble(),
          (json['lng'] as num).toDouble(),
        ),
        state: stopStateFromApi(json['state'] as String?),
        scheduledAt: json['scheduledAt'] as String?,
      );
}

/// The bus's current position and progress along its route.
class LivePosition {
  final LatLng ll;

  /// 0..1 along the route polyline.
  final double progress;
  final double? speedKph;
  final double? headingDeg;
  final int? etaSeconds;
  final int? delaySeconds;
  final DateTime updatedAt;

  /// True when the last fix is old enough that the position should not be
  /// presented as current.
  final bool stale;

  /// "device" (onboard tracker) or "rider" (a phone sharing location).
  final String source;

  const LivePosition({
    required this.ll,
    required this.progress,
    required this.updatedAt,
    required this.stale,
    required this.source,
    this.speedKph,
    this.headingDeg,
    this.etaSeconds,
    this.delaySeconds,
  });

  factory LivePosition.fromJson(Map<String, dynamic> json) => LivePosition(
        ll: LatLng(
          (json['lat'] as num).toDouble(),
          (json['lng'] as num).toDouble(),
        ),
        progress: (json['progress'] as num).toDouble(),
        speedKph: (json['speedKph'] as num?)?.toDouble(),
        headingDeg: (json['headingDeg'] as num?)?.toDouble(),
        etaSeconds: (json['etaSeconds'] as num?)?.round(),
        delaySeconds: (json['delaySeconds'] as num?)?.round(),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch((json['updatedAt'] as num).toInt()),
        stale: json['stale'] == true,
        source: json['source'] as String? ?? 'device',
      );
}

/// Everything the live-status screen renders for one route.
class RouteDetail {
  final String id;
  final String number;
  final String name;
  final BusSignal signal;
  final BusStatusView status;
  final int riders;
  final bool sharing;
  final List<Stop> stops;
  final LivePosition? live;
  final String? scheduledArrival;

  const RouteDetail({
    required this.id,
    required this.number,
    required this.name,
    required this.signal,
    required this.status,
    required this.riders,
    required this.sharing,
    required this.stops,
    required this.live,
    this.scheduledArrival,
  });

  factory RouteDetail.fromJson(Map<String, dynamic> json) => RouteDetail(
        id: json['id'] as String,
        number: json['number'] as String,
        name: json['name'] as String,
        signal: _signalFrom(json['signal'] as String?),
        status: _statusFrom(json['status'] as String?),
        riders: (json['riders'] as num?)?.toInt() ?? 0,
        sharing: json['sharing'] == true,
        scheduledArrival: json['scheduledArrival'] as String?,
        stops: ((json['stops'] as List?) ?? const [])
            .map((e) => Stop.fromJson(e as Map<String, dynamic>))
            .toList(),
        live: json['live'] == null
            ? null
            : LivePosition.fromJson(json['live'] as Map<String, dynamic>),
      );

  Stop? get nextStop {
    for (final s in stops) {
      if (s.state == StopState.next) return s;
    }
    return null;
  }

  /// Minutes to the next stop, or null when there is no live fix.
  int? get etaMinutes {
    final seconds = live?.etaSeconds;
    if (seconds == null) return null;
    final m = (seconds / 60).ceil();
    return m < 1 ? 1 : m;
  }
}

enum BusSignal { good, weak, offline }

BusSignal _signalFrom(String? raw) {
  switch (raw) {
    case 'good':
      return BusSignal.good;
    case 'weak':
      return BusSignal.weak;
    default:
      return BusSignal.offline;
  }
}

enum BusStatusView { onTime, late, weak, offline }

BusStatusView _statusFrom(String? raw) {
  switch (raw) {
    case 'onTime':
      return BusStatusView.onTime;
    case 'late':
      return BusStatusView.late;
    case 'weak':
      return BusStatusView.weak;
    default:
      return BusStatusView.offline;
  }
}
