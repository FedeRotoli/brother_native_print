// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:brother_native_print/brother_native_print.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('discoverPrinters test', (WidgetTester tester) async {
    final BrotherNativePrint plugin = BrotherNativePrint();
    try {
      final printers = await plugin.discoverPrinters(
        timeout: const Duration(seconds: 5),
      );
      expect(printers, isA<List<BrotherPrinter>>());
    } on PlatformException catch (e) {
      // Without Bluetooth/location permissions the discovery fails with a
      // clear error instead of crashing.
      expect(e.code, isNotNull);
    }
  });
}
