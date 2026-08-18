import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:brother_native_print/brother_native_print.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _plugin = BrotherNativePrint();
  StreamSubscription<PrinterStatus>? _statusSubscription;

  List<BrotherPrinter> _printers = <BrotherPrinter>[];
  BrotherPrinter? _selected;
  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  bool _busy = false;
  String _log = '';

  @override
  void initState() {
    super.initState();
    _statusSubscription = _plugin.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _state = status.state);
      _appendLog('Stato: ${status.state.name}');
    });
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }

  void _appendLog(String message) {
    setState(() => _log = '[$_state] $message\n$_log');
  }

  Future<void> _discover() async {
    setState(() => _busy = true);
    try {
      // I permessi sono richiesti dall'app host: il plugin fallisce con un
      // errore chiaro se mancano al momento della discovery Bluetooth.
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      final printers = await _plugin.discoverPrinters();
      setState(() => _printers = printers);
      _appendLog('Trovate ${printers.length} stampanti');
    } on PlatformException catch (e) {
      _appendLog('Discovery fallita: ${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(BrotherPrinter printer) async {
    setState(() => _busy = true);
    try {
      final ok = await _plugin.connect(printer);
      setState(() => _selected = printer);
      _appendLog(
        ok ? 'Connesso a ${printer.serialNumber}' : 'Connessione fallita',
      );
    } on PlatformException catch (e) {
      _appendLog('Connessione fallita: ${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await _plugin.disconnect();
    setState(() => _selected = null);
    _appendLog('Disconnesso');
  }

  Future<void> _printImage() async {
    setState(() => _busy = true);
    try {
      final image = await _buildTestImage();
      final result = await _plugin.printImage(
        image,
        options: const PrintOptions(copies: 1, autoCut: true),
      );
      _appendLog(
        result.success
            ? 'Immagine stampata'
            : 'Errore stampa: ${result.error?.code.name} ${result.error?.message}',
      );
    } on PlatformException catch (e) {
      _appendLog('Errore stampa: ${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _printPdf() async {
    setState(() => _busy = true);
    try {
      final pdfBytes = await _buildTestPdf();
      final result = await _plugin.printPdf(
        pdfBytes,
        options: const PrintOptions(copies: 1, autoCut: true),
      );
      _appendLog(
        result.success
            ? 'PDF stampato'
            : 'Errore stampa: ${result.error?.code.name} ${result.error?.message}',
      );
    } on PlatformException catch (e) {
      _appendLog('Errore stampa: ${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Genera una bitmap di prova 696x271 px (formato RJ-2050 / QL 62mm).
  Future<Uint8List> _buildTestImage() async {
    const width = 696;
    const height = 271;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = Colors.white;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );
    final border = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    canvas.drawRect(
      const Rect.fromLTWH(10, 10, width - 20.0, height - 20.0),
      border,
    );
    final paragraphBuilder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontSize: 48, fontWeight: FontWeight.bold),
          )
          ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
          ..addText('Brother Native Print');
    final paragraph = paragraphBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: width - 80));
    canvas.drawParagraph(paragraph, const Offset(40, 60));

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  }

  /// Genera un PDF di prova in memoria, usando un font embedded (Roboto)
  /// per supportare anche i caratteri accentati/Unicode.
  Future<Uint8List> _buildTestPdf() async {
    final font = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Regular.ttf'),
    );
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: font));
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Center(
          child: pw.Text(
            'Brother Native Print',
            style: pw.TextStyle(fontSize: 32),
          ),
        ),
      ),
    );
    return doc.save();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Brother Native Print demo'),
          actions: [
            IconButton(
              tooltip: 'Cerca stampanti',
              onPressed: _busy ? null : _discover,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 12,
                    color: switch (_state) {
                      PrinterConnectionState.connected => Colors.green,
                      PrinterConnectionState.connecting => Colors.orange,
                      PrinterConnectionState.error => Colors.red,
                      PrinterConnectionState.disconnected => Colors.grey,
                    },
                  ),
                  const SizedBox(width: 8),
                  Text('Stato: ${_state.name}'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _printers.isEmpty
                    ? const Center(
                        child: Text(
                          'Nessuna stampante trovata.\n'
                          'Tocca la lente per cercare.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: _printers.length,
                        itemBuilder: (context, index) {
                          final printer = _printers[index];
                          final selected = printer == _selected;
                          return Card(
                            color: selected ? Colors.blue.shade50 : null,
                            child: ListTile(
                              leading: Icon(
                                printer.connectionType ==
                                        BrotherConnectionType.wifi
                                    ? Icons.wifi
                                    : printer.connectionType ==
                                          BrotherConnectionType.bluetooth
                                    ? Icons.bluetooth
                                    : Icons.usb,
                              ),
                              title: Text(
                                '${printer.model.toUpperCase()} '
                                '(${printer.connectionType.name})',
                              ),
                              subtitle: Text(
                                'IP: ${printer.ipAddress ?? '-'} '
                                'MAC: ${printer.macAddress ?? '-'}\n'
                                'SN: ${printer.serialNumber}',
                              ),
                              trailing: selected
                                  ? TextButton(
                                      onPressed: _disconnect,
                                      child: const Text('Disconnetti'),
                                    )
                                  : TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _connect(printer),
                                      child: const Text('Connetti'),
                                    ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _printImage,
                    icon: const Icon(Icons.image),
                    label: const Text('Stampa immagine'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _printPdf,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Stampa PDF'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _log.isEmpty ? 'Log...' : _log,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
