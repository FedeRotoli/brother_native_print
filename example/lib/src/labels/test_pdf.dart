import 'package:barcode/barcode.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Generates an in-memory test PDF using an embedded font (Roboto) to also
/// support accented/Unicode characters.
Future<Uint8List> buildTestPdf() async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/Roboto-Regular.ttf'),
  );
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: font));
  // A 62×40 mm label, the same format as the image print (62 mm roll).
  final pageFormat = PdfPageFormat(
    62 * PdfPageFormat.mm,
    40 * PdfPageFormat.mm,
    marginAll: 2 * PdfPageFormat.mm,
  );
  doc.addPage(
    pw.Page(
      pageFormat: pageFormat,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'UOVA FRESCHE',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.Text('CATEGORIA A', style: const pw.TextStyle(fontSize: 9)),
          pw.Text(
            'LOTTO: 26-08-2026-001',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.Text('ORIGINE: IT-12345', style: const pw.TextStyle(fontSize: 9)),
          pw.Text(
            'DATA DEPOSIZIONE: 26/08/2026',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 4),
          pw.BarcodeWidget(
            data: '260826001',
            barcode: Barcode.code128(),
            width: 54 * PdfPageFormat.mm,
            height: 12 * PdfPageFormat.mm,
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
