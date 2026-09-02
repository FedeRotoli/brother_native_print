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

  Future<bool> connect(
    BrotherPrinter printer, {
    bool resolveSerialNumber = true,
  }) => throw UnimplementedError('connect() not implemented.');

  Future<void> disconnect() =>
      throw UnimplementedError('disconnect() not implemented.');

  /// Returns the printer currently connected, or `null` when none.
  ///
  /// The logical connection stored by [connect] is kept until [disconnect] is
  /// called (or the plugin is detached), even if the caller navigates to
  /// another screen. This is the data needed to print again without re-running
  /// discovery — useful because a printer that was connected without a proper
  /// disconnect is often "busy" and no longer listed by the discovery.
  Future<BrotherPrinter?> getConnectedPrinter() =>
      throw UnimplementedError('getConnectedPrinter() not implemented.');

  /// Asks the SDK to abort any in-flight print, releasing the channel for a
  /// new attempt. Safe to call while a print is stuck.
  Future<void> cancelPrinting() =>
      throw UnimplementedError('cancelPrinting() not implemented.');

  Future<PrintResult> printImage(Uint8List imageBytes, PrintOptions options) =>
      throw UnimplementedError('printImage() not implemented.');

  Future<PrintResult> printPdf(Uint8List pdfBytes, PrintOptions options) =>
      throw UnimplementedError('printPdf() not implemented.');

  /// Queries the hardware status of the currently connected printer.
  ///
  /// Returns `null` when no printer is connected.
  Future<PrinterHardwareStatus?> getPrinterStatus() =>
      throw UnimplementedError('getPrinterStatus() not implemented.');

  Stream<PrinterStatus> get statusStream =>
      throw UnimplementedError('statusStream not implemented.');
}
