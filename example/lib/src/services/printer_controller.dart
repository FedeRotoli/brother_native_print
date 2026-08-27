import 'dart:async';

import 'package:brother_native_print/brother_native_print.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../labels/test_pdf.dart';
import '../labels/traceability_label.dart';

/// Owns every plugin interaction for the demo app.
///
/// The UI ([HomeScreen]) only renders the state exposed here and forwards the
/// user's actions to this controller, keeping the widgets free of the
/// discovery / connection / printing logic so the app is easy to read and
/// extend.
class PrinterController extends ChangeNotifier {
  PrinterController({BrotherNativePrint? plugin})
    : _plugin = plugin ?? BrotherNativePrint();

  final BrotherNativePrint _plugin;

  StreamSubscription<PrinterStatus>? _statusSubscription;
  StreamSubscription<BrotherPrinter>? _discoverySubscription;

  final List<BrotherPrinter> _printers = [];
  BrotherPrinter? _selected;
  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  bool _busy = false;
  bool _searching = false;

  /// Log lines, newest first.
  final List<String> _logLines = [];

  /// Cached QL label size detected by the printer for the current connection,
  /// so printing does not run a full status round-trip before every job (that
  /// back-to-back pattern is exactly what used to leave the printer "busy").
  /// Refreshed by the Status action and cleared on (re)connect.
  String? _detectedPaperType;

  bool _disposed = false;

  List<BrotherPrinter> get printers => List.unmodifiable(_printers);
  BrotherPrinter? get selected => _selected;
  PrinterConnectionState get state => _state;
  bool get busy => _busy;
  bool get searching => _searching;

  /// The log text, newest line first.
  String get log => _logLines.join('\n');

  /// Starts observing the connection-state stream. Call once from the widget
  /// that owns this controller (e.g. in `initState`).
  void start() {
    _statusSubscription?.cancel();
    _statusSubscription = _plugin.statusStream.listen((status) {
      _state = status.state;
      _appendLog('Status: ${status.state.name}');
    });
    _restoreConnection();
  }

  /// Recovers the connection stored by the plugin when this controller is
  /// (re)created on a new screen.
  ///
  /// A printer connected without a proper disconnect is often still "busy"
  /// and no longer listed by the discovery, so instead of asking the user to
  /// find it again the controller restores the selected printer from
  /// [BrotherNativePrint.getConnectedPrinter], making it immediately ready to
  /// print (the plugin reports the stored connection on the status stream).
  Future<void> _restoreConnection() async {
    try {
      final printer = await _plugin.getConnectedPrinter();
      if (printer == null || _disposed) return;
      _selected = printer;
      _state = PrinterConnectionState.connected;
      _appendLog(
        'Restored connection: '
        '${printer.serialNumber.isNotEmpty ? printer.serialNumber : printer.model}',
      );
    } on PlatformException catch (e) {
      _appendLog('Restore connection failed: ${e.code} ${e.message}');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _discoverySubscription?.cancel();
    _statusSubscription?.cancel();
    super.dispose();
  }

  void _appendLog(String message) {
    if (_disposed) return;
    _logLines.insert(0, '[$_state] $message');
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------

  /// Requests the runtime permissions and starts the streaming discovery.
  Future<void> discover() async {
    // Permissions are requested by the host app: the plugin fails with a
    // clear error if they are missing when the Bluetooth discovery runs.
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    // Stop any previous search before starting a new one.
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;

    _searching = true;
    notifyListeners();

    // Streaming discovery: already-paired Bluetooth printers arrive first,
    // then Wi-Fi/BLE results as the searches complete. The search runs in the
    // background (no _busy), so the Bluetooth printer can be paired right
    // away while the other channels are still searching.
    _discoverySubscription = _plugin.discoverPrintersStream().listen(
      (printer) {
        _printers.add(printer);
        _appendLog('Found ${printer.model} (${printer.connectionType.name})');
      },
      onDone: () {
        _searching = false;
        _appendLog('Discovery completed: ${_printers.length} printers');
      },
      onError: (Object e) {
        _searching = false;
        _appendLog(
          e is PlatformException
              ? 'Discovery failed: ${e.code} ${e.message}'
              : 'Discovery failed: $e',
        );
      },
    );
  }

  /// Cancels the running search (also aborts the native scans).
  void stopSearch() {
    _discoverySubscription?.cancel();
    _discoverySubscription = null;
    _searching = false;
    _appendLog('Search stopped');
  }

  // ---------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------

  Future<void> connect(BrotherPrinter printer) async {
    _busy = true;
    _detectedPaperType = null;
    notifyListeners();
    try {
      final ok = await _plugin.connect(printer);
      _selected = printer;
      _appendLog(
        ok
            ? 'Connected to '
                  '${printer.serialNumber.isNotEmpty ? printer.serialNumber : printer.model}'
            : 'Connection failed',
      );
    } on PlatformException catch (e) {
      _appendLog('Connection failed: ${e.code} ${e.message}');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Connects directly to a Wi-Fi printer by IP address.
  ///
  /// Useful for Wi-Fi Direct / access-point mode, where the SDK discovery
  /// often cannot find the printer (the network search scans the subnet via
  /// broadcast, which is unreliable on the Direct link). The IP is shown on
  /// the printer LCD (Menu → Network → IP Address).
  Future<void> connectByIp(String ip, {String model = 'QL-820NWB'}) async {
    final address = ip.trim();
    if (address.isEmpty) return;
    await connect(
      BrotherPrinter(
        model: model,
        connectionType: BrotherConnectionType.wifi,
        ipAddress: address,
        serialNumber: '',
      ),
    );
  }

  Future<void> disconnect() async {
    await _plugin.disconnect();
    _detectedPaperType = null;
    _selected = null;
    _appendLog('Disconnected');
  }

  // ---------------------------------------------------------------------
  // Printing
  // ---------------------------------------------------------------------

  Future<void> printImage() async {
    _busy = true;
    notifyListeners();
    try {
      final image = await buildTraceabilityLabelPng();
      // Generous timeout: over Bluetooth/BLE the SDK can take a while to
      // confirm the end of the print, even though the label has been printed.
      final result = await _plugin
          .printImage(image, options: await _printOptions())
          .timeout(const Duration(seconds: 60));
      _appendLog(
        result.success
            ? 'Image printed'
            : 'Print error: ${result.error?.code.name} ${result.error?.message}',
      );
    } on TimeoutException {
      await _onPrintTimeout('Image');
    } on PlatformException catch (e) {
      _appendLog('Print error: ${e.code} ${e.message}');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> printPdf() async {
    _busy = true;
    notifyListeners();
    try {
      final pdfBytes = await buildTestPdf();
      // Generous timeout: over Bluetooth/BLE the SDK can take a while to
      // confirm the end of the print, even though the label has been printed.
      final result = await _plugin
          .printPdf(pdfBytes, options: await _printOptions())
          .timeout(const Duration(seconds: 60));
      _appendLog(
        result.success
            ? 'PDF printed'
            : 'Print error: ${result.error?.code.name} ${result.error?.message}',
      );
    } on TimeoutException {
      await _onPrintTimeout('PDF');
    } on PlatformException catch (e) {
      _appendLog('Print error: ${e.code} ${e.message}');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Handles a print timeout: the label may have been printed but the printer
  /// did not confirm within the timeout, so ask the SDK to abort the print so
  /// the connection is not left stuck; the user can retry.
  Future<void> _onPrintTimeout(String kind) async {
    _appendLog(
      '$kind print timed out: the label may have been printed but the printer '
      'did not confirm within 60 s. Aborting the SDK print so the connection '
      'is not stuck; you can retry.',
    );
    await cancelPrinting();
  }

  // ---------------------------------------------------------------------
  // Printer hardware status
  // ---------------------------------------------------------------------

  /// Queries and logs the printer hardware status (errors + detected media),
  /// useful to diagnose why a print does not start.
  ///
  /// The timeout is generous (45 s) because over Bluetooth/BLE the SDK status
  /// response can take many seconds: a short timeout would fire before the
  /// (slow but valid) response arrives and report a misleading "timed out".
  Future<void> queryStatus() async {
    _busy = true;
    notifyListeners();
    try {
      final status = await _plugin.getPrinterStatus().timeout(
        const Duration(seconds: 45),
      );
      if (status == null) {
        _appendLog('No printer connected');
      } else {
        _detectedPaperType = status.detectedPaperType;
        _appendLog(
          'Status: ok=${status.isOk} error=${status.errorCode ?? '-'} '
          'media=${status.mediaWidthMm}x${status.mediaHeightMm}mm '
          '(roll=${status.isHeightInfinite}) '
          'label=${status.detectedPaperType ?? '-'}',
        );
      }
    } on TimeoutException {
      _appendLog('Status query timed out: the printer did not respond');
    } on PlatformException catch (e) {
      _appendLog('Status error: ${e.code} ${e.message}');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Tells the SDK to abort any in-flight print (releases the channel so a
  /// stale print cannot block new communication).
  Future<void> cancelPrinting() async {
    try {
      await _plugin.cancelPrinting();
      _appendLog('Cancel sent: the SDK print has been aborted');
    } on PlatformException catch (e) {
      _appendLog('Cancel failed: ${e.code} ${e.message}');
    }
  }

  // ---------------------------------------------------------------------
  // Print options
  // ---------------------------------------------------------------------

  /// Builds the [PrintOptions] for the connected printer from the bundled
  /// [BrotherPrintPresets].
  ///
  /// For the QL-820NWB the label size is matched to the cassette the printer
  /// actually detected ([PrinterHardwareStatus.detectedPaperType]), so the job
  /// always matches the loaded roll and avoids the "wrong roll type" error; it
  /// falls back to the SDK default 62 mm roll (`RollW62`) if the media is
  /// unknown. For the RJ-2050 the preset provides the 58 mm roll width and the
  /// bundled custom paper `.bin` is loaded into a temporary file the native
  /// side can read.
  Future<PrintOptions> _printOptions({int copies = 1}) async {
    final printer = _selected;
    if (printer == null) return PrintOptions(copies: copies);

    if (printer.model.toUpperCase().contains('QL')) {
      return _qlOptions(copies: copies);
    }

    final binPath = await BrotherCustomPaper.binPathFor(
      model: printer.model,
      widthMm: 58,
    );
    _appendLog(
      binPath != null
          ? 'Custom paper loaded: ${printer.model} 58mm'
          : 'No bundled custom paper for ${printer.model}',
    );
    return BrotherPrintPresets.rj2050Roll58.toOptions(
      copies: copies,
      paperBinPath: binPath,
    );
  }

  /// Picks the QL label size from the cassette the printer detected, falling
  /// back to the SDK default 62 mm roll (`RollW62`) when the media is unknown.
  ///
  /// A short timeout keeps the status query from blocking the print: if the
  /// printer is slow it just uses the default (no error is surfaced).
  Future<PrintOptions> _qlOptions({int copies = 1}) async {
    // Reuse the label the printer detected on the first query: a status query
    // before every print would create two back-to-back operations (status +
    // print) that used to find the printer busy. Refresh it with the Status
    // action or by reconnecting.
    var paperType = _detectedPaperType;
    if (paperType == null || paperType.isEmpty) {
      try {
        final status = await _plugin.getPrinterStatus().timeout(
          const Duration(seconds: 10),
        );
        paperType = status?.detectedPaperType;
        if (paperType != null && paperType.isNotEmpty) {
          _detectedPaperType = paperType;
          _appendLog('Printer detected label: $paperType');
        }
      } on PlatformException catch (e) {
        _appendLog('Status query failed: ${e.code} ${e.message}');
      } on TimeoutException {
        // Slow link: do not block the print, just use the default label.
      }
    }
    if (paperType != null && paperType.isNotEmpty) {
      return PrintOptions(copies: copies, paperType: paperType, autoCut: true);
    }
    return BrotherPrintPresets.ql820NwbRoll62.toOptions(copies: copies);
  }
}
