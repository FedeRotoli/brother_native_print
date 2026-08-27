import 'package:brother_native_print/brother_native_print.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrotherPrintPresets', () {
    test('QL-820NWB 29×90 mm die-cut preset', () {
      final preset = BrotherPrintPresets.ql820NwbDieCut29x90;
      expect(preset.model, 'QL-820NWB');
      expect(preset.paperType, 'DieCutW29H90');
      expect(preset.paperWidthMm, isNull);
      expect(preset.widthMm, 29);
      expect(preset.heightMm, 90);
      expect(preset.dpi, 300);

      final options = preset.toOptions();
      expect(options.paperType, 'DieCutW29H90');
      expect(options.paperWidthMm, isNull);
      expect(options.copies, 1);
      expect(options.autoCut, isTrue);

      // 29×90 mm at 300 dpi.
      expect(preset.imageSize(), (width: 343, height: 1063));
    });

    test('QL-820NWB 62 mm roll preset', () {
      final preset = BrotherPrintPresets.ql820NwbRoll62;
      expect(preset.paperType, 'RollW62');
      expect(preset.heightMm, isNull);
      // 62 mm at 300 dpi.
      expect(preset.imageSize(), (width: 732, height: null));
    });

    test('RJ-2050 58 mm roll preset', () {
      final preset = BrotherPrintPresets.rj2050Roll58;
      expect(preset.model, 'RJ-2050');
      expect(preset.paperType, isNull);
      expect(preset.paperWidthMm, 58);
      expect(preset.heightMm, isNull);
      expect(preset.dpi, 203);

      final options = preset.toOptions(copies: 3, paperBinPath: '/tmp/x.bin');
      expect(options.paperWidthMm, 58);
      expect(options.paperType, isNull);
      expect(options.paperBinPath, '/tmp/x.bin');
      expect(options.copies, 3);

      // 58 mm at 203 dpi.
      expect(preset.imageSize(), (width: 464, height: null));
    });

    test('toOptions copies and autoCut are forwarded', () {
      final options = BrotherPrintPresets.ql820NwbDieCut29x90.toOptions(
        copies: 5,
        autoCut: false,
      );
      expect(options.copies, 5);
      expect(options.autoCut, isFalse);
    });

    test('forMedia matches the cassette loaded in the printer', () {
      expect(
        BrotherPrintPresets.forMedia(
          const PrinterHardwareStatus(
            isOk: true,
            mediaWidthMm: 29,
            mediaHeightMm: 90,
          ),
        ),
        same(BrotherPrintPresets.ql820NwbDieCut29x90),
      );
      expect(
        BrotherPrintPresets.forMedia(
          const PrinterHardwareStatus(
            isOk: true,
            mediaWidthMm: 62,
            isHeightInfinite: true,
          ),
        ),
        same(BrotherPrintPresets.ql820NwbRoll62),
      );
      expect(
        BrotherPrintPresets.forMedia(
          const PrinterHardwareStatus(
            isOk: true,
            mediaWidthMm: 58,
            isHeightInfinite: true,
          ),
        ),
        same(BrotherPrintPresets.rj2050Roll58),
      );
      // Unknown media (width not reported) does not match any preset.
      expect(
        BrotherPrintPresets.forMedia(const PrinterHardwareStatus(isOk: true)),
        isNull,
      );
      // A 29 mm die-cut does not match the 29×90 preset when the height differs.
      expect(
        BrotherPrintPresets.forMedia(
          const PrinterHardwareStatus(
            isOk: true,
            mediaWidthMm: 29,
            mediaHeightMm: 42,
          ),
        ),
        isNull,
      );
    });
  });
}
