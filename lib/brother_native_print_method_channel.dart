import 'package:flutter/services.dart';
import 'brother_native_print_platform_interface.dart';
import 'src/models.dart';

class MethodChannelBrotherNativePrint extends BrotherNativePrintPlatform {
  final methodChannel = const MethodChannel('brother_native_print/methods');
  final eventChannel = const EventChannel('brother_native_print/status');

  @override
  Future<List<BrotherPrinter>> discoverPrinters({
    required Set<BrotherConnectionType> connectionTypes,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await methodChannel
        .invokeMethod<List<dynamic>>('discoverPrinters', {
          'connectionTypes': connectionTypes.map((c) => c.name).toList(),
          'timeoutMs': timeout.inMilliseconds,
        });
    return (result ?? []).map((e) => BrotherPrinter.fromMap(e as Map)).toList();
  }

  @override
  Future<bool> connect(BrotherPrinter printer) async {
    final result = await methodChannel.invokeMethod<bool>(
      'connect',
      printer.toMap(),
    );
    return result ?? false;
  }

  @override
  Future<void> disconnect() => methodChannel.invokeMethod('disconnect');

  @override
  Future<PrintResult> printImage(
    Uint8List imageBytes,
    PrintOptions options,
  ) async {
    final result = await methodChannel.invokeMethod<Map>('printImage', {
      'imageBytes': imageBytes,
      'options': options.toMap(),
    });
    return _toPrintResult(result);
  }

  @override
  Future<PrintResult> printPdf(Uint8List pdfBytes, PrintOptions options) async {
    final result = await methodChannel.invokeMethod<Map>('printPdf', {
      'pdfBytes': pdfBytes,
      'options': options.toMap(),
    });
    return _toPrintResult(result);
  }

  PrintResult _toPrintResult(Map? result) {
    final success = result?['success'] == true;
    if (success || result == null) {
      return PrintResult(success: success);
    }
    final errorMap = result['error'] as Map?;
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
        (errorMap?['message'] as String?) ?? 'Errore di stampa sconosciuto',
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
