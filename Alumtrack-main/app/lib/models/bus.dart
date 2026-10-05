import 'package:latlong2/latlong.dart';

enum BusStatus { onTime, late, weak, off }

BusStatus busStatusFromApi(String? raw) {
  switch (raw) {
    case 'onTime':
      return BusStatus.onTime;
    case 'late':
      return BusStatus.late;
    case 'weak':
      return BusStatus.weak;
    default:
      return BusStatus.off;
  }
}

/// A route as shown in the Buses list.
class Bus {
  final String id;
  final String no;
  final String name;
  final BusStatus status;
  final int? etaSeconds;
  final int? delaySeconds;

  /// Lightweight stop coordinates for the route-preview thumbnail on this
  /// row — not the full detail geometry (that's only fetched for whichever
  /// one route is actually open).
  final List<LatLng> previewPoints;

  const Bus({
    required this.id,
    required this.no,
    required this.name,
    required this.status,
    this.etaSeconds,
    this.delaySeconds,
    this.previewPoints = const [],
  });

  factory Bus.fromJson(Map<String, dynamic> json) => Bus(
        id: json['id'] as String,
        no: json['number'] as String,
        name: json['name'] as String,
        status: busStatusFromApi(json['status'] as String?),
        etaSeconds: (json['etaSeconds'] as num?)?.round(),
        delaySeconds: (json['delaySeconds'] as num?)?.round(),
        previewPoints: ((json['previewPoints'] as List?) ?? const [])
            .map((e) => LatLng(
                  ((e as Map<String, dynamic>)['lat'] as num).toDouble(),
                  (e['lng'] as num).toDouble(),
                ))
            .toList(),
      );

  /// Right-aligned arrival text on the list row.
  String get eta {
    if (status == BusStatus.off || etaSeconds == null) return '—';
    final minutes = (etaSeconds! / 60).ceil();
    final text = '${minutes < 1 ? 1 : minutes} min';
    // A weak fix gives an approximate position, so don't imply precision.
    return status == BusStatus.weak ? '~$text' : text;
  }

  String get statusLabel {
    switch (status) {
      case BusStatus.onTime:
        return 'On Time';
      case BusStatus.late:
        final m = ((delaySeconds ?? 0) / 60).round();
        return 'Delayed ${m < 1 ? 1 : m} min';
      case BusStatus.weak:
        return 'GPS Signal Weak';
      case BusStatus.off:
        return 'Offline';
    }
  }

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return '$no $name $statusLabel'.toLowerCase().contains(q);
  }
}
