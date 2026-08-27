// Temporary helper: renders the traceability label to a PNG file for preview.
//
// NOTE: real file I/O must run inside `tester.runAsync` (flutter_test runs in
// a fake-async zone where such futures never complete, which would hang the
// suite). The file is written with `runAsync` for this reason.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brother_native_print_example/src/labels/traceability_label.dart';

void main() {
  testWidgets('save label preview', (tester) async {
    final bytes = await tester.runAsync(buildTraceabilityLabelPng);
    final file = File('${Directory.systemTemp.path}/traceability_label.png');
    await tester.runAsync(() => file.writeAsBytes(bytes!));
    // ignore: avoid_print
    print('LABEL_PREVIEW_PATH:${file.path}');
  });
}
