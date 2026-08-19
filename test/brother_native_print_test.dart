import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:brother_native_print/brother_native_print.dart';
import 'package:brother_native_print/brother_native_print_platform_interface.dart';
import 'package:brother_native_print/brother_native_print_method_channel.dart';
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
  Future<bool> connect(BrotherPrinter printer) => Future.value(true);

  @override
  Future<void> disconnect() => Future.value();

  @override
  Future<PrintResult> printImage(Uint8List imageBytes, PrintOptions options) =>
      Future.value(const PrintResult(success: true));

  @override
  Future<PrintResult> printPdf(Uint8List pdfBytes, PrintOptions options) =>
      Future.value(const PrintResult(success: true));

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
    BrotherNativePrint brotherNativePrintPlugin = BrotherNativePrint();
    MockBrotherNativePrintPlatform fakePlatform =
        MockBrotherNativePrintPlatform();
    BrotherNativePrintPlatform.instance = fakePlatform;

    final printers = await brotherNativePrintPlugin.discoverPrinters();
    expect(printers, hasLength(1));
    expect(printers.first.model, 'RJ-2050');
    expect(printers.first.ipAddress, '192.168.1.10');
  });

  test('discoverPrintersStream', () async {
    BrotherNativePrint brotherNativePrintPlugin = BrotherNativePrint();
    MockBrotherNativePrintPlatform fakePlatform =
        MockBrotherNativePrintPlatform();
    BrotherNativePrintPlatform.instance = fakePlatform;

    final printers = await brotherNativePrintPlugin
        .discoverPrintersStream()
        .toList();
    expect(printers, hasLength(1));
    expect(printers.first.model, 'QL-820NWB');
    expect(printers.first.connectionType, BrotherConnectionType.bluetooth);
  });
}
