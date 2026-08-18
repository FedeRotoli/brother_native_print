/// Tipo di connessione usata per raggiungere la stampante.
enum BrotherConnectionType { wifi, bluetooth, usb }

/// Descrizione di una stampante Brother trovata durante la discovery.
class BrotherPrinter {
  /// Nome del modello come riportato dall'SDK (es. "RJ-2050", "QL-820NWB",
  /// "TD-4550DNWB", "PT-P900W"...). La discovery non filtra per modello:
  /// vengono restituite tutte le stampanti Brother compatibili trovate.
  final String model;
  final BrotherConnectionType connectionType;
  final String? ipAddress;
  final String? macAddress;
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

/// Opzioni di stampa comuni a immagini e PDF.
class PrintOptions {
  final int copies;

  /// Tipo di carta (etichetta). Rilevante soprattutto per QL-820NWB.
  ///
  /// Valori tipici per QL-820NWB: `RollW62`, `RollW62RB`, `DieCutW62H100`, ecc.
  /// Se nullo, viene usata l'impostazione predefinita dell'SDK.
  final String? paperType;

  /// Taglio automatico a fine stampa (solo modelli QL).
  final bool autoCut;

  const PrintOptions({this.copies = 1, this.paperType, this.autoCut = true});

  Map<String, dynamic> toMap() => {
    'copies': copies,
    'paperType': paperType,
    'autoCut': autoCut,
  };
}

/// Codici di errore normalizzati, indipendenti dalla piattaforma.
enum BrotherPrintErrorCode {
  printerUnreachable,
  bluetoothDisabled,
  permissionMissing,
  outOfPaper,
  coverOpen,
  communicationLost,
  timeout,
  unknown,
}

/// Errore di stampa normalizzato restituito dal plugin.
class BrotherPrintError {
  final BrotherPrintErrorCode code;
  final String message;
  const BrotherPrintError(this.code, this.message);
}

/// Esito di un'operazione di stampa.
class PrintResult {
  final bool success;
  final BrotherPrintError? error;
  const PrintResult({required this.success, this.error});
}

/// Stato di connessione della stampante.
enum PrinterConnectionState { connected, disconnected, connecting, error }

/// Snapshot dello stato della stampante emesso sullo status stream.
class PrinterStatus {
  final PrinterConnectionState state;
  final BrotherPrintError? error;
  const PrinterStatus({required this.state, this.error});
}
