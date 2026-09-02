import 'dart:typed_data';
import 'brother_native_print_platform_interface.dart';
import 'src/models.dart';

export 'src/custom_paper.dart';
export 'src/models.dart';
export 'src/presets.dart';

/// Public API of the Brother Native Print plugin.
///
/// Use [discoverPrinters] to find Brother printers on the network or over
/// Bluetooth, [connect] to open a connection, [printImage] / [printPdf] to
/// print, and [statusStream] to observe the connection state.
class BrotherNativePrint {
  /// Discovers Brother printers.
  ///
  /// [connectionTypes] selects which discovery transports to use. By default
  /// Wi-Fi and Bluetooth are searched; USB is available on Android only.
  ///
  /// Only Brother printers are reported: on Wi-Fi the SDK's network scan is
  /// complemented by probing the phone's subnet directly (unicast SNMP), and
  /// non-Brother devices are filtered out. Discovery is not limited to the
  /// models supported by [connect] — every Brother printer found is returned.
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
  /// Only Brother printers are emitted; the Wi-Fi search also probes the local
  /// subnet with unicast SNMP (some routers/printer firmware ignore the SDK's
  /// broadcast), so printers the SDK network scan misses are still found.
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
  /// When [resolveSerialNumber] is `true` (default), the plugin queries the
  /// serial number over the just-opened connection so [getConnectedPrinter]
  /// can return it even when discovery couldn't report it (Bluetooth/BLE and
  /// connect-by-IP). Set it to `false` to skip that round-trip and speed up
  /// the connection when the serial number is not needed.
  ///
  /// Returns `true` on success.
  Future<bool> connect(
    BrotherPrinter printer, {
    bool resolveSerialNumber = true,
  }) => BrotherNativePrintPlatform.instance.connect(
    printer,
    resolveSerialNumber: resolveSerialNumber,
  );

  /// Closes the connection with the currently connected printer, if any.
  Future<void> disconnect() => BrotherNativePrintPlatform.instance.disconnect();

  /// Returns the printer currently connected, or `null` when none.
  ///
  /// The connection established by [connect] is kept until [disconnect] is
  /// called (or the plugin is detached), even if the caller navigates to
  /// another screen. Use this to recover the connection data (model, IP/MAC
  /// address, serial number) on any screen and print again without re-running
  /// discovery: a printer that was connected without a proper disconnect is
  /// often still "busy" and no longer listed by the discovery.
  Future<BrotherPrinter?> getConnectedPrinter() =>
      BrotherNativePrintPlatform.instance.getConnectedPrinter();

  /// Asks the SDK to abort any in-flight print operation.
  ///
  /// Useful when a print appears stuck (e.g. the SDK is still waiting for the
  /// end-of-print confirmation over a slow link): it releases the channel so
  /// a new print can be attempted. Safe to call even when nothing is printing.
  Future<void> cancelPrinting() =>
      BrotherNativePrintPlatform.instance.cancelPrinting();

  /// Queries the hardware status of the currently connected printer.
  ///
  /// Returns `null` when no printer is connected. The result reports the
  /// printer error state and the media (label) detected by the printer, which
  /// helps diagnose print failures (e.g. a label size mismatch or the printer
  /// being in an unexpected mode).
  Future<PrinterHardwareStatus?> getPrinterStatus() =>
      BrotherNativePrintPlatform.instance.getPrinterStatus();

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
