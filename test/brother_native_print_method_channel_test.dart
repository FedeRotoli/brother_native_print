import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:brother_native_print/brother_native_print.dart';
import 'package:brother_native_print/brother_native_print_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelBrotherNativePrint platform = MethodChannelBrotherNativePrint();
  const MethodChannel channel = MethodChannel('brother_native_print/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'discoverPrinters':
              return [
                {
                  'model': 'rj2050',
                  'connectionType': 'wifi',
                  'ipAddress': '192.168.1.10',
                  'macAddress': 'AA:BB:CC:DD:EE:FF',
                  'serialNumber': 'SN123',
                },
              ];
            case 'printImage':
            case 'printPdf':
              return {'success': true};
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('discoverPrinters', () async {
    final printers = await platform.discoverPrinters(
      connectionTypes: {BrotherConnectionType.wifi},
    );
    expect(printers, hasLength(1));
    expect(printers.first.model, BrotherModel.rj2050);
    expect(printers.first.connectionType, BrotherConnectionType.wifi);
    expect(printers.first.serialNumber, 'SN123');
  });

  test('printImage', () async {
    final result = await platform.printImage(
      Uint8List.fromList([1, 2, 3]),
      const PrintOptions(),
    );
    expect(result.success, isTrue);
  });
}
