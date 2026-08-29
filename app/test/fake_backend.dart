import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory stand-in for the Convex HTTP surface.
///
/// Lets widget and state tests exercise the real [ApiClient]/[BusRepository]
/// code paths — including error handling — without a network.
class FakeBackend {
  FakeBackend({
    this.routes = const [],
    this.detail,
    this.alerts = const [],
    this.unread = 0,
    this.isGuest = false,
    this.linkedRouteId,
  });

  List<Map<String, dynamic>> routes;
  Map<String, dynamic>? detail;
  List<Map<String, dynamic>> alerts;
  int unread;
  bool isGuest;
  String? linkedRouteId;

  /// Paths that should fail, mapped to the status code to return.
  final Map<String, int> failures = {};

  /// Every path this backend was asked for, in order.
  final List<String> requests = [];

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    requests.add(path);

    final failure = failures[path];
    if (failure != null) {
      return http.Response(
        jsonEncode({'error': 'Injected failure'}),
        failure,
        headers: {'content-type': 'application/json'},
      );
    }

    Map<String, dynamic> body;
    switch (path) {
      case '/api/auth/guest':
        body = {'token': 'test-token', 'subject': 'guest:test'};
        break;
      case '/api/me':
        body = {
          'subject': isGuest ? 'guest:test' : 'google:test',
          'isGuest': isGuest,
          'notifyLeadMinutes': 5,
          'linkedRoute': linkedRouteId == null
              ? null
              : {'id': linkedRouteId, 'number': '12', 'name': 'Test route'},
        };
        break;
      case '/api/routes':
        body = {'routes': routes, 'serverNow': _now};
        break;
      case '/api/route':
        body = detail ?? {};
        break;
      case '/api/alerts':
        body = {'unread': unread, 'items': alerts};
        break;
      default:
        body = {'ok': true};
    }

    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  static int get _now => DateTime.now().millisecondsSinceEpoch;

  /// A route-list row with sensible defaults.
  static Map<String, dynamic> route({
    String id = 'r1',
    String number = '12',
    String name = 'Kottayam ⇄ CEK Kidangoor',
    String status = 'onTime',
    int? etaSeconds = 360,
    int? delaySeconds,
  }) =>
      {
        'id': id,
        'number': number,
        'name': name,
        'status': status,
        'etaSeconds': etaSeconds,
        'delaySeconds': delaySeconds,
      };

  /// A full route-detail payload with a three-stop route.
  static Map<String, dynamic> routeDetail({
    String id = 'r1',
    String status = 'onTime',
    String signal = 'good',
    int riders = 3,
    bool sharing = false,
    bool withLive = true,
  }) =>
      {
        'id': id,
        'number': '12',
        'name': 'Kottayam ⇄ CEK Kidangoor',
        'scheduledArrival': '10:05',
        'status': status,
        'signal': signal,
        'riders': riders,
        'sharing': sharing,
        'stops': [
          {
            'seq': 0,
            'name': 'Kottayam KSRTC',
            'lat': 9.5926,
            'lng': 76.5222,
            'scheduledAt': '09:22',
            'state': 'past',
          },
          {
            'seq': 1,
            'name': 'Ayarkunnam',
            'lat': 9.639,
            'lng': 76.585,
            'scheduledAt': '09:46',
            'state': 'next',
          },
          {
            'seq': 2,
            'name': 'CEK Kidangoor',
            'lat': 9.6655,
            'lng': 76.6285,
            'scheduledAt': '10:05',
            'state': 'ahead',
          },
        ],
        'live': withLive
            ? {
                'lat': 9.62,
                'lng': 76.57,
                'progress': 0.42,
                'speedKph': 32.0,
                'headingDeg': 45.0,
                'etaSeconds': 360,
                'delaySeconds': 0,
                'updatedAt': _now,
                'source': 'device',
                'stale': false,
              }
            : null,
      };

  static Map<String, dynamic> alert({
    String id = 'a1',
    String kind = 'arriving',
    String message = 'Your bus is 5 minutes away',
    String? routeNumber = '12',
    bool unread = true,
  }) =>
      {
        'id': id,
        'kind': kind,
        'message': message,
        'routeNumber': routeNumber,
        'createdAt': _now,
        'unread': unread,
      };
}
