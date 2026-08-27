import 'package:brother_native_print/brother_native_print.dart';
import 'package:brother_native_print/brother_native_print_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelBrotherNativePrint platform =
      MethodChannelBrotherNativePrint();
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
            case 'getStatus':
              return {
                'isOk': true,
                'errorCode': null,
                'mediaWidthMm': 62,
                'mediaHeightMm': 0,
                'isHeightInfinite': true,
                'detectedPaperType': 'RollW62',
              };
            case 'getConnectedPrinter':
              return {
                'model': 'QL-820NWB',
                'connectionType': 'bluetooth',
                'macAddress': '11:22:33:44:55:66',
                'serialNumber': 'SN456',
              };
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

  test('getPrinterStatus maps the native map', () async {
    final status = await platform.getPrinterStatus();
    expect(status, isNotNull);
    expect(status!.isOk, isTrue);
    expect(status.errorCode, isNull);
    expect(status.mediaWidthMm, 62);
    expect(status.mediaHeightMm, 0);
    expect(status.isHeightInfinite, isTrue);
    expect(status.detectedPaperType, 'RollW62');
  });

  test('getPrinterStatus returns null when disconnected', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (MethodCall methodCall) async => null,
        );
    expect(await platform.getPrinterStatus(), isNull);
  });

  test('getConnectedPrinter maps the native map', () async {
    final printer = await platform.getConnectedPrinter();
    expect(printer, isNotNull);
    expect(printer!.model, 'QL-820NWB');
    expect(printer.connectionType, BrotherConnectionType.bluetooth);
    expect(printer.macAddress, '11:22:33:44:55:66');
    expect(printer.serialNumber, 'SN456');
  });

  test(
    'getConnectedPrinter returns null when no printer is connected',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (MethodCall methodCall) async => null,
          );
      expect(await platform.getConnectedPrinter(), isNull);
    },
  );

  test('cancelPrinting invokes the method channel', () async {
    String? invoked;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          invoked = methodCall.method;
          return null;
        });
    await platform.cancelPrinting();
    expect(invoked, 'cancelPrinting');
  });
}
