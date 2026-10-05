import '../models/bus.dart';
import '../models/notification_item.dart';
import '../models/stop.dart';
import 'api_client.dart';

/// The signed-in user's profile and preferences.
class Profile {
  final String subject;
  final String? name;
  final String? email;
  final bool isGuest;
  final int notifyLeadMinutes;
  final String? linkedRouteId;
  final String? linkedRouteNumber;

  const Profile({
    required this.subject,
    required this.isGuest,
    required this.notifyLeadMinutes,
    this.name,
    this.email,
    this.linkedRouteId,
    this.linkedRouteNumber,
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    final linked = json['linkedRoute'] as Map<String, dynamic>?;
    return Profile(
      subject: json['subject'] as String,
      name: json['name'] as String?,
      email: json['email'] as String?,
      isGuest: json['isGuest'] == true,
      notifyLeadMinutes: (json['notifyLeadMinutes'] as num?)?.toInt() ?? 5,
      linkedRouteId: linked?['id'] as String?,
      linkedRouteNumber: linked?['number'] as String?,
    );
  }
}

class AlertFeed {
  final int unread;
  final List<NotificationGroup> groups;

  const AlertFeed({required this.unread, required this.groups});

  bool get isEmpty => groups.isEmpty;
}

/// All backend reads and writes the UI needs, in one place.
class BusRepository {
  BusRepository(this._api);

  final ApiClient _api;

  Future<Profile> profile() async =>
      Profile.fromJson(await _api.get('/api/me'));

  Future<Profile> updatePreferences({
    int? notifyLeadMinutes,
    String? linkedRouteId,
  }) async {
    final body = <String, dynamic>{};
    if (notifyLeadMinutes != null) body['notifyLeadMinutes'] = notifyLeadMinutes;
    if (linkedRouteId != null) body['linkedRouteId'] = linkedRouteId;
    return Profile.fromJson(await _api.post('/api/me', body));
  }

  Future<List<Bus>> routes() async {
    final res = await _api.get('/api/routes');
    return ((res['routes'] as List?) ?? const [])
        .map((e) => Bus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<RouteDetail> routeDetail(String routeId) async =>
      RouteDetail.fromJson(await _api.get('/api/route', query: {'id': routeId}));

  Future<AlertFeed> alerts() async {
    final res = await _api.get('/api/alerts');
    final items = ((res['items'] as List?) ?? const [])
        .map((e) => NotificationItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return AlertFeed(
      unread: (res['unread'] as num?)?.toInt() ?? 0,
      groups: NotificationGroup.group(items),
    );
  }

  Future<void> markAlertsRead() => _api.post('/api/alerts/read');

  /// Starts or stops rider-assisted tracking. Returns the active rider count.
  Future<int> setSharing({
    required String routeId,
    required bool active,
  }) async {
    final res = await _api.post('/api/share', {
      'routeId': routeId,
      'active': active,
    });
    return (res['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> submitRiderFix({
    required String routeId,
    required double lat,
    required double lng,
    double? speedKph,
    double? headingDeg,
    double? accuracyM,
  }) =>
      _api.post('/api/share/fix', {
        'routeId': routeId,
        'lat': lat,
        'lng': lng,
        'speedKph': ?speedKph,
        'headingDeg': ?headingDeg,
        'accuracyM': ?accuracyM,
      });

  /// Rates one completed trip. `tripEndedAt` identifies which trip — the
  /// final stop's live-state timestamp at the moment the app decided the
  /// journey was over — so re-submitting for the same trip updates rather
  /// than duplicates.
  Future<void> submitFeedback({
    required String routeId,
    required int rating,
    required int tripEndedAt,
    String? comment,
  }) =>
      _api.post('/api/feedback', {
        'routeId': routeId,
        'rating': rating,
        'tripEndedAt': tripEndedAt,
        'comment': ?comment,
      });
}
