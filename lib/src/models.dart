/// Transport used to reach a printer.
enum BrotherConnectionType { wifi, bluetooth, usb }

/// A Brother printer discovered on the network or over Bluetooth.
class BrotherPrinter {
  /// Model name as reported by the SDK (e.g. "RJ-2050", "QL-820NWB",
  /// "TD-4550DNWB", "PT-P900W"...). Discovery does not filter by model: every
  /// compatible Brother printer found is returned.
  final String model;
  final BrotherConnectionType connectionType;
  final String? ipAddress;

  /// MAC address, when the SDK/discovery can report one: Wi-Fi printers (read
  /// via SNMP `ifPhysAddress`) and classic Bluetooth on Android (the device
  /// address). `null` for BLE, where the OS hides the BLE MAC for privacy.
  final String? macAddress;

  /// Serial number as reported by the SDK. Note that discovery leaves it empty
  /// for Bluetooth and Wi-Fi printers (the SDK only reports it over an active
  /// connection): use [BrotherNativePrint.getConnectedPrinter] after
  /// connecting to obtain the resolved serial number.
  final String serialNumber;

  const BrotherPrinter({
    required this.model,
    required this.connectionType,
    this.ipAddress,
    this.macAddress,
    required this.serialNumber,
  });

  factory BrotherPrinter.fromMap(Map<dynamic, dynamic> map) => BrotherPrinter(
    model: map['model'] as String? ?? 'Unknown',
    connectionType: BrotherConnectionType.values.firstWhere(
      (c) => c.name == map['connectionType'],
    ),
    ipAddress: map['ipAddress'] as String?,
    macAddress: map['macAddress'] as String?,
    serialNumber: map['serialNumber'] as String,
  );

  Map<String, dynamic> toMap() => {
    'model': model,
    'connectionType': connectionType.name,
    'ipAddress': ipAddress,
    'macAddress': macAddress,
    'serialNumber': serialNumber,
  };
}

/// Print options shared by image and PDF printing.
class PrintOptions {
  /// Number of copies to print (defaults to `1`).
  final int copies;

  /// Label (paper) size. Relevant mainly for QL-820NWB.
  ///
  /// Typical values for QL-820NWB: `RollW62`, `RollW62RB`, `DieCutW62H100`, ...
  /// When `null`, the SDK default is used.
  final String? paperType;

  /// Whether to auto-cut after printing (QL models only, defaults to `true`).
  final bool autoCut;

  /// Roll width in mm for custom paper (RJ models).
  ///
  /// RJ printers (e.g. RJ-2050) with rolls that are not recognized by the SDK
  /// (e.g. third-party rolls) require an explicit custom paper size. Default:
  /// 58 mm for the RJ-2050.
  final double? paperWidthMm;

  /// Path (on the device) to a `.bin` file containing the printer's custom
  /// paper definition, generated with Brother Paper Size Setup Tool.
  ///
  /// When provided, it takes precedence over [paperWidthMm] and is used as a
  /// custom paper via `BRLMCustomPaperSize(file:)` (iOS) or
  /// `CustomPaperSize.newFile()` (Android).
  final String? paperBinPath;

  const PrintOptions({
    this.copies = 1,
    this.paperType,
    this.autoCut = true,
    this.paperWidthMm,
    this.paperBinPath,
  });

  Map<String, dynamic> toMap() => {
    'copies': copies,
    'paperType': paperType,
    'autoCut': autoCut,
    'paperWidthMm': paperWidthMm,
    'paperBinPath': paperBinPath,
  };
}

/// Normalized, platform-independent error codes.
enum BrotherPrintErrorCode {
  /// The printer could not be reached or no printer is connected.
  printerUnreachable,

  /// Bluetooth is disabled on the device.
  bluetoothDisabled,

  /// Required runtime permissions are missing.
  permissionMissing,

  /// The printer is out of paper.
  outOfPaper,

  /// The printer cover is open.
  coverOpen,

  /// Communication with the printer was lost.
  communicationLost,

  /// The operation timed out.
  timeout,

  /// Any other, unclassified error.
  unknown,
}

/// A normalized print error returned by the plugin.
class BrotherPrintError {
  /// Machine-readable error code.
  final BrotherPrintErrorCode code;

  /// Human-readable error description.
  final String message;

  const BrotherPrintError(this.code, this.message);
}

/// Outcome of a print operation.
class PrintResult {
  /// Whether the operation completed successfully.
  final bool success;

  /// Present when [success] is `false`.
  final BrotherPrintError? error;

  const PrintResult({required this.success, this.error});
}

/// Connection state of the printer.
enum PrinterConnectionState { connected, disconnected, connecting, error }

/// A snapshot of the printer state emitted on the status stream.
class PrinterStatus {
  /// Current connection state.
  final PrinterConnectionState state;

  /// Present when [state] is [PrinterConnectionState.error].
  final BrotherPrintError? error;

  const PrinterStatus({required this.state, this.error});
}

/// Hardware status of the connected printer, as reported by the SDK.
///
/// This is the physical printer state (errors and detected media), distinct
/// from [PrinterStatus] which tracks the connection state. Use
/// `BrotherNativePrint.getPrinterStatus()` to query it on demand, e.g. to
/// diagnose why a print fails (label size mismatch, printer in an unexpected
/// mode, out of paper...).
class PrinterHardwareStatus {
  /// True when the SDK reports no printer error.
  final bool isOk;

  /// Normalized error code (`outOfPaper`, `coverOpen`, `paperJam`, `busy`,
  /// ...) or `null` when [isOk] is true.
  final String? errorCode;

  /// Detected media (label/roll) width in mm, `0` when unknown.
  final int mediaWidthMm;

  /// Detected media height in mm, `0` for continuous rolls or when unknown.
  final int mediaHeightMm;

  /// True when the media is a continuous roll (infinite height, e.g. RJ or a
  /// QL roll label).
  final bool isHeightInfinite;

  /// Exact QL label size detected by the printer (e.g. `RollW62`,
  /// `RollW62RB`, `DieCutW62H100`), or `null` when unknown or the printer is
  /// not a QL model.
  ///
  /// Pass it as [PrintOptions.paperType] to match the cassette actually loaded
  /// and avoid the printer's "wrong roll type" error.
  final String? detectedPaperType;

  const PrinterHardwareStatus({
    required this.isOk,
    this.errorCode,
    this.mediaWidthMm = 0,
    this.mediaHeightMm = 0,
    this.isHeightInfinite = false,
    this.detectedPaperType,
  });

  factory PrinterHardwareStatus.fromMap(Map<dynamic, dynamic> map) =>
      PrinterHardwareStatus(
        isOk: map['isOk'] as bool? ?? false,
        errorCode: map['errorCode'] as String?,
        mediaWidthMm: (map['mediaWidthMm'] as num?)?.toInt() ?? 0,
        mediaHeightMm: (map['mediaHeightMm'] as num?)?.toInt() ?? 0,
        isHeightInfinite: map['isHeightInfinite'] as bool? ?? false,
        detectedPaperType: map['detectedPaperType'] as String?,
      );
}
