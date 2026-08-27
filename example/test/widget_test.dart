// Basic smoke test for the example app.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:brother_native_print_example/src/app.dart';
import 'package:brother_native_print_example/src/labels/traceability_label.dart';

void main() {
  testWidgets('Example app builds and shows the initial state', (tester) async {
    await tester.pumpWidget(const MyApp());

    // The app bar title is rendered.
    expect(find.text('Brother Native Print demo'), findsOneWidget);

    // No printers found yet: the initial hint is shown.
    expect(find.textContaining('No printers found'), findsOneWidget);
  });

  testWidgets('Traceability label renders a valid PNG', (tester) async {
    final Uint8List bytes =
        await tester.runAsync(() => buildTraceabilityLabelPng()) as Uint8List;

    // PNG magic bytes + non-empty payload (barcode + text lines).
    expect(bytes.length, greaterThan(100));
    expect(bytes.sublist(0, 8), [
      0x89, 0x50, 0x4E, 0x47, // PNG
      0x0D, 0x0A, 0x1A, 0x0A,
    ]);
  });
}
