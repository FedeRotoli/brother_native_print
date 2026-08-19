// Basic smoke test for the example app.

import 'package:flutter_test/flutter_test.dart';

import 'package:brother_native_print_example/main.dart';

void main() {
  testWidgets('Example app builds and shows the initial state', (tester) async {
    await tester.pumpWidget(const MyApp());

    // The app bar title is rendered.
    expect(find.text('Brother Native Print demo'), findsOneWidget);

    // No printers found yet: the initial hint is shown.
    expect(find.textContaining('No printers found'), findsOneWidget);
  });
}
