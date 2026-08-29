import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stubs the platform channels the app touches.
///
/// Without these, calls into flutter_secure_storage and google_sign_in hang
/// in the test binding — there is no platform side to answer them.
void installPluginMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final store = <String, String>{};

  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          if (key != null) store[key] = args['value'] as String? ?? '';
          return null;
        case 'read':
          return key == null ? null : store[key];
        case 'delete':
          if (key != null) store.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(store);
        case 'deleteAll':
          store.clear();
          return null;
        case 'containsKey':
          return key != null && store.containsKey(key);
        default:
          return null;
      }
    },
  );

  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/google_sign_in'),
    (call) async => null,
  );

  messenger.setMockMethodCallHandler(
    const MethodChannel('flutter.baseflow.com/geolocator'),
    (call) async => null,
  );
}
