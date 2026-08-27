import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:barcode/barcode.dart';
import 'package:brother_native_print/brother_native_print.dart';
import 'package:flutter/material.dart';

/// Builds a mock traceability label (e.g. eggs) as a PNG bitmap.
///
/// Renders plain text strings plus a Code 128 barcode: no fancy graphics,
/// sized for a 62 mm continuous roll (the QL-820NWB SDK default), ~300 dpi.
/// Exposed top-level so it can be tested (a private method cannot be called
/// from a test in another library).
Future<Uint8List> buildTraceabilityLabelPng() async {
  // 62 mm roll: width from the bundled preset, height is the demo label length.
  final width = BrotherPrintPresets.ql820NwbRoll62.imageSize().width.toDouble();
  const height = 420.0;
  const margin = 16.0;
  final contentWidth = width - 2 * margin;

  const titleText = 'UOVA FRESCHE';
  const lines = <String>[
    'CATEGORIA A - 6 UOVA',
    'LOTTO: 26-08-2026-001',
    'ORIGINE: IT-12345',
    'DEPOSIZIONE: 26/08/2026',
    'CONSUMO RACCOMANDATO: 23/09/2026',
  ];
  const traceCode = '260826001';

  final title = _buildLabelParagraph(
    titleText,
    width: contentWidth,
    fontSize: 34,
    bold: true,
  );
  final body = [
    for (final line in lines)
      _buildLabelParagraph(line, width: contentWidth, fontSize: 20),
  ];
  final code = _buildLabelParagraph(
    traceCode,
    width: contentWidth,
    fontSize: 22,
    center: true,
  );

  const lineGap = 10.0;
  const sectionGap = 18.0;
  const barcodeHeight = 90.0;
  const codeGap = 8.0;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // White background.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = Colors.white,
  );

  double y = 24;
  canvas.drawParagraph(title, Offset(margin, y));
  y += title.height + sectionGap;
  for (final paragraph in body) {
    canvas.drawParagraph(paragraph, Offset(margin, y));
    y += paragraph.height + lineGap;
  }
  y -= lineGap; // Remove the trailing gap added by the loop.
  y += sectionGap;

  // Code 128 barcode encoding the traceability code.
  final barcode = Barcode.code128();
  final barcodeTop = y;
  final blackPaint = Paint()..color = const Color(0xFF000000);
  for (final element in barcode.make(
    traceCode,
    width: contentWidth,
    height: barcodeHeight,
  )) {
    if (element is BarcodeBar && element.black) {
      canvas.drawRect(
        Rect.fromLTWH(
          margin + element.left,
          barcodeTop + element.top,
          element.width,
          element.height,
        ),
        blackPaint,
      );
    }
  }

  // Human-readable code below the barcode.
  canvas.drawParagraph(
    code,
    Offset(margin, barcodeTop + barcodeHeight + codeGap),
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.round(), height.round());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

/// Builds a [ui.Paragraph] laid out to [width], used for a line of the label.
ui.Paragraph _buildLabelParagraph(
  String text, {
  required double width,
  required double fontSize,
  bool bold = false,
  bool center = false,
}) {
  final builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            textAlign: center ? TextAlign.center : TextAlign.left,
          ),
        )
        ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
        ..addText(text);
  return builder.build()..layout(ui.ParagraphConstraints(width: width));
}
