import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Role of a signed-in staff account.
enum AdminRole { admin, superadmin }

AdminRole _roleFrom(String raw) =>
    raw == 'superadmin' ? AdminRole.superadmin : AdminRole.admin;

class AdminSession {
  final String token;
  final String email;
  final String name;
  final AdminRole role;

  const AdminSession({
    required this.token,
    required this.email,
    required this.name,
    required this.role,
  });

  bool get isSuperadmin => role == AdminRole.superadmin;
}

/// One boarding stop on a bus's route, as surfaced to the admin dashboard
/// for pinning a student to a specific pickup point, and for editing the
/// route's geometry (lat/lng, ordering, and the start<->end direction).
class AdminStop {
  final String id;
  final int seq;
  final String name;
  final double? lat;
  final double? lng;
  final String? scheduledAt;

  AdminStop({
    required this.id,
    required this.seq,
    required this.name,
    this.lat,
    this.lng,
    this.scheduledAt,
  });

  factory AdminStop.fromJson(Map<String, dynamic> j) => AdminStop(
        id: j['id'] as String,
        seq: j['seq'] as int,
        name: j['name'] as String,
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        scheduledAt: j['scheduledAt'] as String?,
      );
}

class AdminBus {
  final String id;
  final String number;
  final String name;
  final bool active;
  final String? scheduledArrival;
  final List<AdminStop> stops;

  AdminBus({
    required this.id,
    required this.number,
    required this.name,
    required this.active,
    this.scheduledArrival,
    this.stops = const [],
  });

  factory AdminBus.fromJson(Map<String, dynamic> j) => AdminBus(
        id: j['id'] as String,
        number: j['number'] as String,
        name: j['name'] as String,
        active: j['active'] as bool,
        scheduledArrival: j['scheduledArrival'] as String?,
        stops: ((j['stops'] as List?) ?? const [])
            .map((e) => AdminStop.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class AdminDevice {
  final String id;
  final String deviceId;
  final String routeId;
  final String? routeNumber;
  final String? label;
  final bool revoked;
  final int? lastSeen;

  AdminDevice({
    required this.id,
    required this.deviceId,
    required this.routeId,
    this.routeNumber,
    this.label,
    required this.revoked,
    this.lastSeen,
  });

  factory AdminDevice.fromJson(Map<String, dynamic> j) => AdminDevice(
        id: j['id'] as String,
        deviceId: j['deviceId'] as String,
        routeId: j['routeId'] as String,
        routeNumber: j['routeNumber'] as String?,
        label: j['label'] as String?,
        revoked: j['revoked'] as bool,
        lastSeen: j['lastSeen'] as int?,
      );
}

class AdminAccount {
  final String id;
  final String email;
  final String name;
  final AdminRole role;
  final bool active;
  final int createdAt;
  final int? lastLoginAt;

  AdminAccount({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.active,
    required this.createdAt,
    this.lastLoginAt,
  });

  factory AdminAccount.fromJson(Map<String, dynamic> j) => AdminAccount(
        id: j['id'] as String,
        email: j['email'] as String,
        name: j['name'] as String,
        role: _roleFrom(j['role'] as String),
        active: j['active'] as bool,
        createdAt: j['createdAt'] as int,
        lastLoginAt: j['lastLoginAt'] as int?,
      );
}

class AdminStudent {
  final String subject;
  final String? email;
  final String? name;
  final String? pictureUrl;
  final String? linkedRouteId;
  final String? linkedRouteNumber;
  final String? linkedStopId;
  final String? linkedStopName;
  final int lastSeenAt;

  AdminStudent({
    required this.subject,
    this.email,
    this.name,
    this.pictureUrl,
    this.linkedRouteId,
    this.linkedRouteNumber,
    this.linkedStopId,
    this.linkedStopName,
    required this.lastSeenAt,
  });

  factory AdminStudent.fromJson(Map<String, dynamic> j) => AdminStudent(
        subject: j['subject'] as String,
        email: j['email'] as String?,
        name: j['name'] as String?,
        pictureUrl: j['pictureUrl'] as String?,
        linkedRouteId: j['linkedRouteId'] as String?,
        linkedRouteNumber: j['linkedRouteNumber'] as String?,
        linkedStopId: j['linkedStopId'] as String?,
        linkedStopName: j['linkedStopName'] as String?,
        lastSeenAt: j['lastSeenAt'] as int,
      );
}

/// Staff-side API surface.
///
/// Deliberately its own [ApiClient] (and its own stored token) rather than
/// sharing the student [AuthService]'s — an admin session must never collide
/// with whatever a shared device happens to be signed into as a student.
class AdminService {
  AdminService() : _api = ApiClient();

  final ApiClient _api;
  static const _tokenKey = 'alumtrack.admin.session.token';

  bool get _useSecureStorage => !kIsWeb;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  Future<void> _write(String key, String value) async {
    if (_useSecureStorage) {
      await _secure.write(key: key, value: value);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  Future<String?> _read(String key) async {
    if (_useSecureStorage) return _secure.read(key: key);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> _delete(String key) async {
    if (_useSecureStorage) {
      await _secure.delete(key: key);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    }
  }

  /// Reloads a stored staff session, or null when there is none / it expired.
  Future<AdminSession?> restore() async {
    final token = await _read(_tokenKey);
    if (token == null) return null;
    _api.token = token;
    try {
      final me = await _api.get('/api/admin/me');
      return AdminSession(
        token: token,
        email: me['email'] as String,
        name: me['name'] as String,
        role: _roleFrom(me['role'] as String),
      );
    } on ApiException {
      await _delete(_tokenKey);
      _api.token = null;
      return null;
    }
  }

  Future<AdminSession> login(String email, String password) async {
    final res = await _api.post('/api/auth/admin-login', {
      'email': email,
      'password': password,
    });
    final session = AdminSession(
      token: res['token'] as String,
      email: res['email'] as String,
      name: res['name'] as String,
      role: _roleFrom(res['role'] as String),
    );
    await _write(_tokenKey, session.token);
    _api.token = session.token;
    return session;
  }

  Future<void> signOut() async {
    await _delete(_tokenKey);
    _api.token = null;
  }

  // --- Buses / routes ------------------------------------------------------

  Future<List<AdminBus>> buses() async {
    final res = await _api.get('/api/admin/routes');
    return (res['routes'] as List)
        .map((e) => AdminBus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createBus({
    required String number,
    required String name,
    String? scheduledArrival,
  }) {
    return _api.post('/api/admin/routes', {
      'number': number,
      'name': name,
      if (scheduledArrival != null && scheduledArrival.isNotEmpty)
        'scheduledArrival': scheduledArrival,
    });
  }

  Future<void> setBusActive(String routeId, bool active) {
    return _api.post('/api/admin/routes/update', {
      'routeId': routeId,
      'active': active,
    });
  }

  /// Replaces a route's entire stop list — used both for direct editing and
  /// for "Reverse direction" (the same stops, reordered end-to-start), since
  /// the server always fully replaces a route's stops rather than patching
  /// individual ones.
  Future<void> setRouteStops(String routeId, List<AdminStop> stops) {
    return _api.post('/api/admin/routes/stops', {
      'routeId': routeId,
      'stops': [
        for (var i = 0; i < stops.length; i++)
          {
            'seq': i,
            'name': stops[i].name,
            'lat': stops[i].lat,
            'lng': stops[i].lng,
            if (stops[i].scheduledAt != null) 'scheduledAt': stops[i].scheduledAt,
          },
      ],
    });
  }

  Future<List<AdminDevice>> devices() async {
    final res = await _api.get('/api/admin/devices');
    return (res['devices'] as List)
        .map((e) => AdminDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Returns the plaintext device token — shown once, never retrievable again.
  Future<String> provisionDevice({
    required String deviceId,
    required String routeId,
    String? label,
  }) async {
    final res = await _api.post('/api/admin/devices', {
      'deviceId': deviceId,
      'routeId': routeId,
      if (label != null && label.isNotEmpty) 'label': label,
    });
    return res['token'] as String;
  }

  Future<void> revokeDevice(String deviceId) {
    return _api.post('/api/admin/devices/revoke', {'deviceId': deviceId});
  }

  // --- Admins (superadmin only) --------------------------------------------

  Future<List<AdminAccount>> admins() async {
    final res = await _api.get('/api/admin/admins');
    return (res['admins'] as List)
        .map((e) => AdminAccount.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createAdmin({
    required String email,
    required String password,
    required String name,
  }) {
    return _api.post('/api/admin/admins', {
      'email': email,
      'password': password,
      'name': name,
    });
  }

  Future<void> setAdminActive(String adminId, bool active) {
    return _api.post('/api/admin/admins/active', {
      'adminId': adminId,
      'active': active,
    });
  }

  // --- Students --------------------------------------------------------------

  Future<List<AdminStudent>> students() async {
    final res = await _api.get('/api/admin/students');
    return (res['students'] as List)
        .map((e) => AdminStudent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> removeStudent(String subject) {
    return _api.post('/api/admin/students/remove', {'subject': subject});
  }

  /// Bulk-assigns (or clears, when [routeId] is null) which bus a set of
  /// students is restricted to.
  Future<void> assignStudentsToRoute(List<String> subjects, String? routeId) {
    return _api.post('/api/admin/students/assign-route', {
      'subjects': subjects,
      'routeId': routeId,
    });
  }

  /// Bulk-pins (or clears, when [stopId] is null) which stop on their bus a
  /// set of students boards at.
  Future<void> assignStudentsToStop(List<String> subjects, String? stopId) {
    return _api.post('/api/admin/students/assign-stop', {
      'subjects': subjects,
      'stopId': stopId,
    });
  }

  // --- Notify ------------------------------------------------------------------

  Future<void> notifyAll(String message) {
    return _api.post('/api/admin/notify', {'message': message, 'kind': 'service'});
  }
}
