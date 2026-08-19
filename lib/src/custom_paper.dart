import 'dart:io';

import 'package:flutter/services.dart';

/// Helpers for the custom paper `.bin` files bundled with this package.
///
/// The package ships custom paper definitions (generated with the Brother
/// Paper Size Setup Tool) for the supported RJ/TD models. They are declared as
/// package assets, so applications using this plugin get them automatically and
/// don't need to copy any file.
///
/// The native side requires a real file path ([PrintOptions.paperBinPath]), so
/// use [copyToFile] / [binPathFor] to extract a bundled asset into a temporary
/// file.
class BrotherCustomPaper {
  BrotherCustomPaper._();

  /// Root path used to reference this package's custom paper assets, e.g.
  /// `packages/brother_native_print/custom_paper`.
  static const String assetRoot = 'packages/brother_native_print/custom_paper';

  /// The asset subfolder for [model], following the
  /// `Custom<Model>Paper` convention (e.g. `RJ-2050` → `CustomRJ2050Paper`).
  ///
  /// Returns `null` if the model does not map to a known naming convention.
  static String? folderFor(String model) {
    final normalized = _normalize(model);
    if (normalized.isEmpty) return null;
    return '$assetRoot/Custom${normalized}Paper';
  }

  /// Resolves the bundled asset path for [model] and [widthMm], following the
  /// `Custom<Model>Paper/<Model>-RD<width>mm.bin` convention.
  ///
  /// For example, `assetPathFor(model: 'RJ-2050', widthMm: 58)` returns
  /// `packages/brother_native_print/custom_paper/CustomRJ2050Paper/RJ2050-RD58mm.bin`.
  ///
  /// Returns `null` when [model] or [widthMm] don't match a resolvable asset.
  static String? assetPathFor({
    required String model,
    required double widthMm,
  }) {
    final normalized = _normalize(model);
    final width = widthMm.round();
    if (normalized.isEmpty || width <= 0) return null;
    return '$assetRoot/Custom${normalized}Paper/$normalized-RD${width}mm.bin';
  }

  /// Loads the bundled asset at [assetPath] (e.g. from [assetPathFor]) and
  /// writes it to a temporary file on the device.
  ///
  /// Returns the file path, ready to be passed as
  /// `PrintOptions.paperBinPath`, or `null` if the asset could not be loaded.
  static Future<String?> copyToFile(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      final name = assetPath.split('/').last;
      final file = File('${Directory.systemTemp.path}/$name');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Resolves and extracts the bundled custom paper for [model] and [widthMm]
  /// in one call.
  ///
  /// Returns a temporary file path usable as `PrintOptions.paperBinPath`, or
  /// `null` if no asset matches the requested model/width.
  static Future<String?> binPathFor({
    required String model,
    required double widthMm,
  }) {
    final asset = assetPathFor(model: model, widthMm: widthMm);
    return asset == null ? Future.value(null) : copyToFile(asset);
  }

  static String _normalize(String model) =>
      model.toUpperCase().replaceAll('-', '');
}
