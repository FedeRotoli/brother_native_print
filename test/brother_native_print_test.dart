import 'dart:typed_data';

import 'package:brother_native_print/brother_native_print.dart';
import 'package:brother_native_print/brother_native_print_method_channel.dart';
import 'package:brother_native_print/brother_native_print_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockBrotherNativePrintPlatform
    with MockPlatformInterfaceMixin
    implements BrotherNativePrintPlatform {
  @override
  Future<List<BrotherPrinter>> discoverPrinters({
    required Set<BrotherConnectionType> connectionTypes,
    Duration timeout = const Duration(seconds: 10),
  }) => Future.value([
    const BrotherPrinter(
      model: 'RJ-2050',
      connectionType: BrotherConnectionType.wifi,
      ipAddress: '192.168.1.10',
      serialNumber: 'SN123',
    ),
  ]);

  @override
  Stream<BrotherPrinter> discoverPrintersStream({
    required Set<BrotherConnectionType> connectionTypes,
    Duration timeout = const Duration(seconds: 10),
  }) => Stream.value(
    const BrotherPrinter(
      model: 'QL-820NWB',
      connectionType: BrotherConnectionType.bluetooth,
      macAddress: '11:22:33:44:55:66',
      serialNumber: 'SN456',
    ),
  );

  @override
  Future<bool> connect(
    BrotherPrinter printer, {
    bool resolveSerialNumber = true,
  }) => Future.value(true);

  @override
  Future<void> disconnect() => Future.value();

  @override
  Future<BrotherPrinter?> getConnectedPrinter() async => const BrotherPrinter(
    model: 'QL-820NWB',
    connectionType: BrotherConnectionType.bluetooth,
    macAddress: '11:22:33:44:55:66',
    serialNumber: 'SN456',
  );

  @override
  Future<void> cancelPrinting() => Future.value();

  @override
  Future<PrintResult> printImage(Uint8List imageBytes, PrintOptions options) =>
      Future.value(const PrintResult(success: true));

  @override
  Future<PrintResult> printPdf(Uint8List pdfBytes, PrintOptions options) =>
      Future.value(const PrintResult(success: true));

  @override
  Future<PrinterHardwareStatus?> getPrinterStatus() async =>
      const PrinterHardwareStatus(
        isOk: true,
        mediaWidthMm: 62,
        isHeightInfinite: true,
      );

  @override
  Stream<PrinterStatus> get statusStream => const Stream.empty();
}

void main() {
  final BrotherNativePrintPlatform initialPlatform =
      BrotherNativePrintPlatform.instance;

  test('$MethodChannelBrotherNativePrint is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelBrotherNativePrint>());
  });

  test('discoverPrinters', () async {
    final BrotherNativePrint brotherNativePrintPlugin = BrotherNativePrint();
    final MockBrotherNativePrintPlatform fakePlatform =
        MockBrotherNativePrintPlatform();
    BrotherNativePrintPlatform.instance = fakePlatform;

    final printers = await brotherNativePrintPlugin.discoverPrinters();
    expect(printers, hasLength(1));
    expect(printers.first.model, 'RJ-2050');
    expect(printers.first.ipAddress, '192.168.1.10');
  });

  test('discoverPrintersStream', () async {
    final BrotherNativePrint brotherNativePrintPlugin = BrotherNativePrint();
    final MockBrotherNativePrintPlatform fakePlatform =
        MockBrotherNativePrintPlatform();
    BrotherNativePrintPlatform.instance = fakePlatform;

    final printers = await brotherNativePrintPlugin
        .discoverPrintersStream()
        .toList();
    expect(printers, hasLength(1));
    expect(printers.first.model, 'QL-820NWB');
    expect(printers.first.connectionType, BrotherConnectionType.bluetooth);
  });

  test('getPrinterStatus', () async {
    final BrotherNativePrint brotherNativePrintPlugin = BrotherNativePrint();
    final MockBrotherNativePrintPlatform fakePlatform =
        MockBrotherNativePrintPlatform();
    BrotherNativePrintPlatform.instance = fakePlatform;

    final status = await brotherNativePrintPlugin.getPrinterStatus();
    expect(status, isNotNull);
    expect(status!.isOk, isTrue);
    expect(status.mediaWidthMm, 62);
    expect(status.isHeightInfinite, isTrue);
  });

  test('getConnectedPrinter returns the stored connection', () async {
    final BrotherNativePrint brotherNativePrintPlugin = BrotherNativePrint();
    final MockBrotherNativePrintPlatform fakePlatform =
        MockBrotherNativePrintPlatform();
    BrotherNativePrintPlatform.instance = fakePlatform;

    final printer = await brotherNativePrintPlugin.getConnectedPrinter();
    expect(printer, isNotNull);
    expect(printer!.model, 'QL-820NWB');
    expect(printer.connectionType, BrotherConnectionType.bluetooth);
    expect(printer.serialNumber, 'SN456');
  });

  test('PrinterHardwareStatus.fromMap', () {
    final status = PrinterHardwareStatus.fromMap({
      'isOk': false,
      'errorCode': 'outOfPaper',
      'mediaWidthMm': 29,
      'mediaHeightMm': 90,
      'isHeightInfinite': false,
      'detectedPaperType': 'DieCutW29H90',
    });
    expect(status.isOk, isFalse);
    expect(status.errorCode, 'outOfPaper');
    expect(status.mediaWidthMm, 29);
    expect(status.mediaHeightMm, 90);
    expect(status.isHeightInfinite, isFalse);
    expect(status.detectedPaperType, 'DieCutW29H90');
  });
}
