import 'dart:typed_data';
import 'brother_native_print_platform_interface.dart';
import 'src/models.dart';

export 'src/models.dart';

/// API pubblica del plugin Brother Native Print.
///
/// Supporta le stampanti Brother RJ-2050 e QL-820NWB via WiFi, Bluetooth (BLE)
/// e USB, con stampa di immagini e PDF.
class BrotherNativePrint {
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

  Future<bool> connect(BrotherPrinter printer) =>
      BrotherNativePrintPlatform.instance.connect(printer);

  Future<void> disconnect() => BrotherNativePrintPlatform.instance.disconnect();

  Future<PrintResult> printImage(
    Uint8List imageBytes, {
    PrintOptions options = const PrintOptions(),
  }) => BrotherNativePrintPlatform.instance.printImage(imageBytes, options);

  Future<PrintResult> printPdf(
    Uint8List pdfBytes, {
    PrintOptions options = const PrintOptions(),
  }) => BrotherNativePrintPlatform.instance.printPdf(pdfBytes, options);

  Stream<PrinterStatus> get statusStream =>
      BrotherNativePrintPlatform.instance.statusStream;
}
