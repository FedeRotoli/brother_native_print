import 'dart:typed_data';
import 'brother_native_print_platform_interface.dart';
import 'src/models.dart';

export 'src/custom_paper.dart';
export 'src/models.dart';

/// Public API of the Brother Native Print plugin.
///
/// Use [discoverPrinters] to find Brother printers on the network or over
/// Bluetooth, [connect] to open a connection, [printImage] / [printPdf] to
/// print, and [statusStream] to observe the connection state.
class BrotherNativePrint {
  /// Discovers compatible Brother printers.
  ///
  /// [connectionTypes] selects which discovery transports to use. By default
  /// Wi-Fi and Bluetooth are searched; USB is available on Android only.
  ///
  /// Discovery does **not** filter by model: every compatible Brother printer
  /// reported by the SDK is returned.
  ///
  /// On Android 12+, Bluetooth permissions (`BLUETOOTH_SCAN`,
  /// `BLUETOOTH_CONNECT`) must be granted at runtime before calling this
  /// method, otherwise a `permissionMissing` error is thrown.
  ///
  /// Equivalent to collecting [discoverPrintersStream] into a list: use that
  /// instead to show printers as soon as they are found.
  Future<List<BrotherPrinter>> discoverPrinters({
    Set<BrotherConnectionType> connectionTypes = const {
      BrotherConnectionType.wifi,
      BrotherConnectionType.bluetooth,
    },
    Duration timeout = const Duration(seconds: 10),
  }) => BrotherNativePrintPlatform.instance.discoverPrinters(
    connectionTypes: connectionTypes,
    timeout: timeout,
  );

  /// Starts discovery and yields each printer as soon as it is found.
  ///
  /// Already-paired Bluetooth printers are emitted first (typically within
  /// milliseconds), while Wi-Fi, BLE and USB results arrive as the searches
  /// complete: the UI can update live instead of waiting for the whole
  /// discovery to finish. The searches run in parallel, so the total time is
  /// roughly [timeout], not the sum of the per-transport timeouts.
  ///
  /// The stream completes when all the requested searches finish. Errors in a
  /// single transport (e.g. missing Bluetooth permissions) are logged and do
  /// not abort the other transports.
  Stream<BrotherPrinter> discoverPrintersStream({
    Set<BrotherConnectionType> connectionTypes = const {
      BrotherConnectionType.wifi,
      BrotherConnectionType.bluetooth,
    },
    Duration timeout = const Duration(seconds: 10),
  }) => BrotherNativePrintPlatform.instance.discoverPrintersStream(
    connectionTypes: connectionTypes,
    timeout: timeout,
  );

  /// Connects to [printer].
  ///
  /// Only the RJ-2050 and QL-820NWB models are currently supported; passing a
  /// different model throws an `invalidArgument` [PlatformException].
  ///
  /// Returns `true` on success.
  Future<bool> connect(BrotherPrinter printer) =>
      BrotherNativePrintPlatform.instance.connect(printer);

  /// Closes the connection with the currently connected printer, if any.
  Future<void> disconnect() => BrotherNativePrintPlatform.instance.disconnect();

  /// Prints an image (PNG or JPEG) encoded in [imageBytes].
  ///
  /// Returns a [PrintResult] describing the outcome. When the operation fails,
  /// [PrintResult.error] contains a normalized [BrotherPrintErrorCode].
  Future<PrintResult> printImage(
    Uint8List imageBytes, {
    PrintOptions options = const PrintOptions(),
  }) => BrotherNativePrintPlatform.instance.printImage(imageBytes, options);

  /// Prints the PDF document encoded in [pdfBytes].
  ///
  /// Returns a [PrintResult] describing the outcome. When the operation fails,
  /// [PrintResult.error] contains a normalized [BrotherPrintErrorCode].
  Future<PrintResult> printPdf(
    Uint8List pdfBytes, {
    PrintOptions options = const PrintOptions(),
  }) => BrotherNativePrintPlatform.instance.printPdf(pdfBytes, options);

  /// A broadcast stream of [PrinterStatus] snapshots emitted whenever the
  /// connection state of the currently connected printer changes.
  Stream<PrinterStatus> get statusStream =>
      BrotherNativePrintPlatform.instance.statusStream;
}
