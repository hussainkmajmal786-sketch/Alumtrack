import 'package:campus_bus_tracker/data/api_client.dart';
import 'package:campus_bus_tracker/data/auth_service.dart';
import 'package:campus_bus_tracker/data/bus_repository.dart';
import 'package:campus_bus_tracker/main.dart';
import 'package:campus_bus_tracker/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fake_backend.dart';
import 'plugin_mocks.dart';

AppState buildState(FakeBackend backend) {
  final api = ApiClient(client: backend.client, baseUrl: 'https://test.local');
  return AppState(
    api: api,
    auth: AuthService(api),
    repository: BusRepository(api),
  );
}

Future<void> pumpApp(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: const CampusBusTrackerApp(),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installPluginMocks);

  testWidgets('signed-out users see both sign-in options', (tester) async {
    final state = buildState(FakeBackend())..bootstrapping = false;
    await pumpApp(tester, state);

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue as Guest'), findsOneWidget);
  });

  testWidgets('the bus list renders routes from the backend', (tester) async {
    final backend = FakeBackend(
      routes: [
        FakeBackend.route(id: 'r1', number: '12'),
        FakeBackend.route(
          id: 'r2',
          number: '27',
          name: 'Manthadi Loop',
          status: 'weak',
        ),
      ],
    );
    final state = buildState(backend)
      ..bootstrapping = false
      ..session = const Session(
        token: 't',
        subject: 'google:test',
        isGuest: false,
      );

    await state.refreshList();
    state.screen = AppScreen.list;
    await pumpApp(tester, state);

    expect(find.text('Manthadi Loop'), findsOneWidget);
    expect(find.text('GPS Signal Weak'), findsOneWidget);
    expect(find.textContaining('2 routes'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry', (tester) async {
    final backend = FakeBackend()..failures['/api/routes'] = 500;
    final state = buildState(backend)
      ..bootstrapping = false
      ..session = const Session(
        token: 't',
        subject: 'google:test',
        isGuest: false,
      );

    await state.refreshList();
    state.screen = AppScreen.list;
    await pumpApp(tester, state);

    expect(state.listState, Loadable.failed);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a 401 drops the session and returns to sign-in', (tester) async {
    final backend = FakeBackend()..failures['/api/routes'] = 401;
    final state = buildState(backend)
      ..bootstrapping = false
      ..session = const Session(
        token: 't',
        subject: 'google:test',
        isGuest: false,
      );

    await state.refreshList();
    await pumpApp(tester, state);

    expect(state.session, isNull);
    expect(state.screen, AppScreen.auth);
  });
}
