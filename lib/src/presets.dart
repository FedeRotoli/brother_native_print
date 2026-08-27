import 'models.dart';

/// A ready-to-use print preset for a supported printer model.
///
/// Presets bundle the label dimensions that have been validated against a
/// real printer (see [BrotherPrintPresets]), so an app doesn't have to
/// remember the SDK paper codes (`paperType`) or roll widths
/// (`paperWidthMm`). Each preset maps onto the same [PrintOptions] fields:
/// presets are only a convenience — for a custom label, build a
/// [PrintOptions] directly as usual.
class BrotherPrintPreset {
  /// Printer model this preset applies to (e.g. "QL-820NWB").
  final String model;

  /// Human-readable name of the preset (e.g. "Die-cut 29×90 mm").
  final String name;

  /// QL label size, passed as [PrintOptions.paperType] (e.g. "DieCutW29H90").
  final String? paperType;

  /// RJ roll width in mm, passed as [PrintOptions.paperWidthMm].
  final double? paperWidthMm;

  /// Physical label width in mm (informative, e.g. to size a preview image).
  final double widthMm;

  /// Physical label height in mm, or `null` for continuous rolls (RJ series).
  final double? heightMm;

  /// Print resolution targeted by [imageSize] (dpi of the printer).
  final double dpi;

  const BrotherPrintPreset({
    required this.model,
    required this.name,
    required this.widthMm,
    this.paperType,
    this.paperWidthMm,
    this.heightMm,
    this.dpi = 300,
  });

  /// Builds a [PrintOptions] for this preset.
  ///
  /// [paperBinPath] is only relevant for RJ presets (bundled custom paper).
  PrintOptions toOptions({
    int copies = 1,
    bool autoCut = true,
    String? paperBinPath,
  }) {
    return PrintOptions(
      copies: copies,
      paperType: paperType,
      autoCut: autoCut,
      paperWidthMm: paperWidthMm,
      paperBinPath: paperBinPath,
    );
  }

  /// Pixel size of the label at the preset [dpi], useful to render the image
  /// to print. The height is `null` for continuous rolls (RJ series).
  ({int width, int? height}) imageSize() {
    final width = (widthMm / 25.4 * dpi).round();
    final height = heightMm == null ? null : (heightMm! / 25.4 * dpi).round();
    return (width: width, height: height);
  }
}

/// Presets for the printer models this package was tested against.
///
/// They only cover the configurations that have been validated on real
/// hardware; everything else keeps using [PrintOptions] with custom values.
abstract final class BrotherPrintPresets {
  BrotherPrintPresets._();

  /// QL-820NWB — die-cut 29×90 mm label (tested).
  ///
  /// DK cassette `DieCutW29H90`, 300 dpi.
  static const ql820NwbDieCut29x90 = BrotherPrintPreset(
    model: 'QL-820NWB',
    name: 'Die-cut 29×90 mm',
    paperType: 'DieCutW29H90',
    widthMm: 29,
    heightMm: 90,
    dpi: 300,
  );

  /// QL-820NWB — 62 mm continuous roll (the SDK default label size).
  ///
  /// DK cassette `RollW62`, 300 dpi.
  static const ql820NwbRoll62 = BrotherPrintPreset(
    model: 'QL-820NWB',
    name: 'Roll 62 mm',
    paperType: 'RollW62',
    widthMm: 62,
    dpi: 300,
  );

  /// RJ-2050 — 58 mm continuous roll (tested, the default custom paper width).
  ///
  /// 203 dpi printhead: the plugin applies the default margins
  /// (top/right/bottom/left = 3/2/3/2 mm), so the printable area is 54 mm.
  static const rj2050Roll58 = BrotherPrintPreset(
    model: 'RJ-2050',
    name: 'Roll 58 mm',
    paperWidthMm: 58,
    widthMm: 58,
    dpi: 203,
  );

  /// All bundled presets, in definition order. Used by [forMedia] to match
  /// the media reported by the printer.
  static const List<BrotherPrintPreset> all = [
    ql820NwbDieCut29x90,
    ql820NwbRoll62,
    rj2050Roll58,
  ];

  /// Returns the preset whose physical dimensions match the media reported by
  /// the printer, or `null` if no bundled preset matches.
  ///
  /// [PrinterHardwareStatus] comes from `BrotherNativePrint.getPrinterStatus()`:
  /// it reports the cassette actually loaded in the printer, so this selects
  /// the correct label size even when the app doesn't know which label was
  /// inserted (e.g. it avoids the "wrong roll type" printer error).
  static BrotherPrintPreset? forMedia(PrinterHardwareStatus status) {
    if (status.mediaWidthMm <= 0) return null;
    for (final preset in all) {
      if (preset.heightMm == null) {
        // Continuous roll preset.
        if (status.isHeightInfinite &&
            status.mediaWidthMm == preset.widthMm.round()) {
          return preset;
        }
      } else if (!status.isHeightInfinite &&
          status.mediaWidthMm == preset.widthMm.round() &&
          status.mediaHeightMm == preset.heightMm!.round()) {
        return preset;
      }
    }
    return null;
  }
}
