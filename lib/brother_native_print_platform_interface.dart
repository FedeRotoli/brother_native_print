import 'dart:typed_data';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'brother_native_print_method_channel.dart';
import 'src/models.dart';

abstract class BrotherNativePrintPlatform extends PlatformInterface {
  BrotherNativePrintPlatform() : super(token: _token);

  static final Object _token = Object();
  static BrotherNativePrintPlatform _instance =
      MethodChannelBrotherNativePrint();

  static BrotherNativePrintPlatform get instance => _instance;

  static set instance(BrotherNativePrintPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<List<BrotherPrinter>> discoverPrinters({
    required Set<BrotherConnectionType> connectionTypes,
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError('discoverPrinters() not implemented.');

  /// Starts discovery and yields each printer as soon as it is found.
  ///
  /// Already-paired Bluetooth printers are emitted first (no waiting for the
  /// scans); Wi-Fi, BLE and USB results arrive as the searches complete. The
  /// stream completes when all the requested searches finish.
  Stream<BrotherPrinter> discoverPrintersStream({
    required Set<BrotherConnectionType> connectionTypes,
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError('discoverPrintersStream() not implemented.');

  Future<bool> connect(BrotherPrinter printer) =>
      throw UnimplementedError('connect() not implemented.');

  Future<void> disconnect() =>
      throw UnimplementedError('disconnect() not implemented.');

  Future<PrintResult> printImage(Uint8List imageBytes, PrintOptions options) =>
      throw UnimplementedError('printImage() not implemented.');

  Future<PrintResult> printPdf(Uint8List pdfBytes, PrintOptions options) =>
      throw UnimplementedError('printPdf() not implemented.');

  Stream<PrinterStatus> get statusStream =>
      throw UnimplementedError('statusStream not implemented.');
}
