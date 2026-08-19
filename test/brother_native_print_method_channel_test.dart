import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:brother_native_print/brother_native_print.dart';
import 'package:brother_native_print/brother_native_print_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelBrotherNativePrint platform = MethodChannelBrotherNativePrint();
  const MethodChannel channel = MethodChannel('brother_native_print/methods');
  const EventChannel discoveryChannel = EventChannel(
    'brother_native_print/discovery',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'printImage':
            case 'printPdf':
              return {'success': true};
            default:
              return null;
          }
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          discoveryChannel,
          MockStreamHandler.inline(
            onListen: (Object? arguments, MockStreamHandlerEventSink events) {
              events.success({
                'model': 'RJ-2050',
                'connectionType': 'wifi',
                'ipAddress': '192.168.1.10',
                'macAddress': 'AA:BB:CC:DD:EE:FF',
                'serialNumber': 'SN123',
              });
              events.success({
                'model': 'QL-820NWB',
                'connectionType': 'bluetooth',
                'macAddress': '11:22:33:44:55:66',
                'serialNumber': 'SN456',
              });
              events.endOfStream();
            },
            onCancel: (Object? arguments) {},
          ),
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(discoveryChannel, null);
  });

  test('discoverPrintersStream streams printers as they are found', () async {
    final printers = await platform
        .discoverPrintersStream(connectionTypes: {BrotherConnectionType.wifi})
        .toList();
    expect(printers, hasLength(2));
    expect(printers.first.model, 'RJ-2050');
    expect(printers.first.connectionType, BrotherConnectionType.wifi);
    expect(printers.first.serialNumber, 'SN123');
    expect(printers.last.model, 'QL-820NWB');
    expect(printers.last.connectionType, BrotherConnectionType.bluetooth);
    expect(printers.last.serialNumber, 'SN456');
  });

  test('discoverPrinters collects the discovery stream into a list', () async {
    final printers = await platform.discoverPrinters(
      connectionTypes: {BrotherConnectionType.wifi},
    );
    expect(printers, hasLength(2));
    expect(printers.first.serialNumber, 'SN123');
    expect(printers.last.serialNumber, 'SN456');
  });

  test('printImage', () async {
    final result = await platform.printImage(
      Uint8List.fromList([1, 2, 3]),
      const PrintOptions(),
    );
    expect(result.success, isTrue);
  });
}
