import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:campus_bus_tracker/main.dart';
import 'package:campus_bus_tracker/state/app_state.dart';

void main() {
  testWidgets('Auth screen renders sign-in options', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const CampusBusTrackerApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue as Guest'), findsOneWidget);
  });
}
