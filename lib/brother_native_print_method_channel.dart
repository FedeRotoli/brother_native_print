import 'package:flutter/services.dart';
import 'brother_native_print_platform_interface.dart';
import 'src/models.dart';

class MethodChannelBrotherNativePrint extends BrotherNativePrintPlatform {
  final methodChannel = const MethodChannel('brother_native_print/methods');
  final eventChannel = const EventChannel('brother_native_print/status');
  final _discoveryChannel = const EventChannel(
    'brother_native_print/discovery',
  );

  @override
  Future<List<BrotherPrinter>> discoverPrinters({
    required Set<BrotherConnectionType> connectionTypes,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final printers = <BrotherPrinter>[];
    await for (final printer in discoverPrintersStream(
      connectionTypes: connectionTypes,
      timeout: timeout,
    )) {
      printers.add(printer);
    }
    return printers;
  }

  @override
  Stream<BrotherPrinter> discoverPrintersStream({
    required Set<BrotherConnectionType> connectionTypes,
    Duration timeout = const Duration(seconds: 10),
  }) {
    // The native side starts the discovery when the stream is listened to:
    // it emits the already-paired Bluetooth printers first, then the Wi-Fi,
    // BLE and USB results as the searches complete, and finally closes the
    // stream. Subscribing before anything is emitted avoids missing results.
    return _discoveryChannel
        .receiveBroadcastStream({
          'connectionTypes': connectionTypes.map((c) => c.name).toList(),
          'timeoutMs': timeout.inMilliseconds,
        })
        .map((event) {
          final map = Map<String, dynamic>.from(event as Map);
          return BrotherPrinter.fromMap(map);
        });
  }

  @override
  Future<bool> connect(
    BrotherPrinter printer, {
    bool resolveSerialNumber = true,
  }) async {
    final result = await methodChannel.invokeMethod<bool>('connect', {
      ...printer.toMap(),
      'resolveSerialNumber': resolveSerialNumber,
    });
    return result ?? false;
  }

  @override
  Future<void> disconnect() => methodChannel.invokeMethod('disconnect');

  @override
  Future<BrotherPrinter?> getConnectedPrinter() async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'getConnectedPrinter',
    );
    if (result == null) return null;
    return BrotherPrinter.fromMap(result);
  }

  @override
  Future<void> cancelPrinting() => methodChannel.invokeMethod('cancelPrinting');

  @override
  Future<PrintResult> printImage(
    Uint8List imageBytes,
    PrintOptions options,
  ) async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'printImage',
      {'imageBytes': imageBytes, 'options': options.toMap()},
    );
    return _toPrintResult(result);
  }

  @override
  Future<PrintResult> printPdf(Uint8List pdfBytes, PrintOptions options) async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'printPdf',
      {'pdfBytes': pdfBytes, 'options': options.toMap()},
    );
    return _toPrintResult(result);
  }

  @override
  Future<PrinterHardwareStatus?> getPrinterStatus() async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'getStatus',
    );
    if (result == null) return null;
    return PrinterHardwareStatus.fromMap(result);
  }

  PrintResult _toPrintResult(Map<dynamic, dynamic>? result) {
    final success = result?['success'] == true;
    if (success || result == null) {
      return PrintResult(success: success);
    }
    final errorMap = result['error'] as Map<dynamic, dynamic>?;
    final codeName = errorMap?['code'] as String?;
    final code = codeName != null
        ? BrotherPrintErrorCode.values.firstWhere(
            (c) => c.name == codeName,
            orElse: () => BrotherPrintErrorCode.unknown,
          )
        : BrotherPrintErrorCode.unknown;
    return PrintResult(
      success: false,
      error: BrotherPrintError(
        code,
        (errorMap?['message'] as String?) ?? 'Unknown print error',
      ),
    );
  }

  @override
  Stream<PrinterStatus> get statusStream =>
      eventChannel.receiveBroadcastStream().map(
        (event) => PrinterStatus(
          state: PrinterConnectionState.values.firstWhere(
            (s) => s.name == (event as Map)['state'],
          ),
        ),
      );
}
