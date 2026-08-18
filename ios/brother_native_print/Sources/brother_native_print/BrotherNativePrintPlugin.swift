import CoreBluetooth
import Flutter
import Foundation
import ImageIO
import BRLMPrinterKit

// Nomi delle classi SDK verificati sugli header di BRLMPrinterKit.xcframework
// (variante BT_Net, per RJ-2050 e QL-820NWB che richiedono il Bluetooth).

/// Errore interno del plugin, convertito in FlutterError al confine del canale.
private struct PluginFailure: Error {
  let code: String
  let message: String
}

public class BrotherNativePrintPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  // Canali trovati nell'ultima discovery, per riaprire la connessione.
  private var discoveredChannels: [String: BRLMChannel] = [:]
  private var currentDriver: BRLMPrinterDriver?
  private var currentModel: BRLMPrinterModel?
  private let queue = DispatchQueue(label: "brother_native_print.queue", qos: .userInitiated)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "brother_native_print/methods",
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: "brother_native_print/status",
      binaryMessenger: registrar.messenger()
    )
    let instance = BrotherNativePrintPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { result(FlutterError(code: "unknown", message: "Plugin rilasciato", details: nil)) }
        return
      }
      do {
        let output = try self.handleSync(call)
        DispatchQueue.main.async { result(output) }
      } catch let failure as PluginFailure {
        DispatchQueue.main.async {
          result(FlutterError(code: failure.code, message: failure.message, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "unknown", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // MARK: - Metodi

  private func handleSync(_ call: FlutterMethodCall) throws -> Any? {
    switch call.method {
    case "discoverPrinters":
      return try discoverPrinters(call)
    case "connect":
      return try connect(call)
    case "disconnect":
      disconnect()
      return nil
    case "printImage":
      return try printImage(call)
    case "printPdf":
      return try printPdf(call)
    default:
      return FlutterMethodNotImplemented
    }
  }

  // MARK: - Discovery

  private func discoverPrinters(_ call: FlutterMethodCall) throws -> [[String: Any?]] {
    let args = call.arguments as? [String: Any] ?? [:]
    let connectionTypes = (args["connectionTypes"] as? [String])?.map { $0 } ?? ["wifi", "bluetooth"]
    let timeoutMs = (args["timeoutMs"] as? Int) ?? 10_000
    let duration = max(TimeInterval(timeoutMs) / 1000.0, 1.0)

    var channels: [String: BRLMChannel] = [:]

    if connectionTypes.contains("wifi") {
      let option = BRLMNetworkSearchOption()
      option.searchDuration = duration
      let result = BRLMPrinterSearcher.startNetworkSearch(option) { _ in
        // I canali vengono raccolti dal risultato sincrono.
      }
      if result.error.code != .noError {
        print("[BrotherNativePrint] Ricerca Wi-Fi fallita: \(result.error.code.rawValue)")
      } else {
        result.channels.forEach { channels[Self.channelKey($0)] = $0 }
      }
    }

    if connectionTypes.contains("bluetooth") {
      #if targetEnvironment(simulator)
      print("[BrotherNativePrint] ATTENZIONE: il simulatore iOS non supporta il Bluetooth")
      #endif
      try ensureBluetoothAccess()
      let option = BRLMBLESearchOption()
      option.searchDuration = duration
      let bleResult = BRLMPrinterSearcher.startBLESearch(option) { _ in }
      if bleResult.error.code == .noError {
        bleResult.channels.forEach { channels[Self.channelKey($0)] = $0 }
      } else {
        print("[BrotherNativePrint] Ricerca BLE fallita: \(bleResult.error.code.rawValue)")
      }
      // Bluetooth classico (MFi/SPP): trova solo stampanti GIÀ ACCOPPIATE
      // in Impostazioni > Bluetooth (i modelli RJ-2050/QL-820NWB usano SPP,
      // non BLE).
      let btResult = BRLMPrinterSearcher.startBluetoothSearch()
      if btResult.error.code == .noError {
        btResult.channels.forEach { channels[Self.channelKey($0)] = $0 }
      } else {
        print("[BrotherNativePrint] Ricerca Bluetooth classico fallita: \(btResult.error.code.rawValue)")
      }
    }

    print("[BrotherNativePrint] Discovery: trovati \(channels.count) canali")

    // USB non è supportato dal kit iOS: restituisce sempre lista vuota.

    synchronized {
      discoveredChannels = channels
    }

    return channels.values.map { channelToMap($0) }
  }

  private func ensureBluetoothAccess() throws {
    // iOS 13.1+: autorizzazione Bluetooth da parte dell'utente.
    if #available(iOS 13.1, *) {
      switch CBManager.authorization {
      case .denied, .restricted:
        throw PluginFailure(
          code: "permissionMissing",
          message: "Accesso Bluetooth negato: abilitarlo nelle impostazioni"
        )
      default:
        break
      }
    }
  }

  // MARK: - Connessione

  private func connect(_ call: FlutterMethodCall) throws -> Bool {
    guard let args = call.arguments as? [String: Any] else {
      throw PluginFailure(code: "invalidArgument", message: "Argomenti connessione mancanti")
    }
    guard let modelName = args["model"] as? String else {
      throw PluginFailure(code: "invalidArgument", message: "Campo 'model' mancante")
    }
    let model: BRLMPrinterModel
    if modelName.caseInsensitiveCompare("RJ-2050") == .orderedSame {
      model = .RJ_2050
    } else if modelName.caseInsensitiveCompare("QL-820NWB") == .orderedSame {
      model = .QL_820NWB
    } else {
      throw PluginFailure(code: "invalidArgument", message: "Modello non supportato: \(modelName)")
    }
    guard let connectionType = args["connectionType"] as? String else {
      throw PluginFailure(code: "invalidArgument", message: "Campo 'connectionType' mancante")
    }
    let ip = args["ipAddress"] as? String
    let mac = args["macAddress"] as? String
    let serial = args["serialNumber"] as? String

    let channel = try resolveChannel(type: connectionType, ip: ip, mac: mac, serial: serial)

    let openResult = BRLMPrinterDriverGenerator.open(channel)
    let openError = openResult.error
    if openError.code != .noError {
      throw PluginFailure(
        code: openChannelErrorCode(openError.code),
        message: openError.errorRecoverySuggestion ?? "Impossibile aprire il canale"
      )
    }
    guard let driver = openResult.driver else {
      throw PluginFailure(code: "communicationLost", message: "Driver non disponibile")
    }

    synchronized {
      currentDriver?.closeChannel()
      currentDriver = driver
      currentModel = model
    }
    emitState("connected")
    return true
  }

  private func resolveChannel(
    type: String,
    ip: String?,
    mac: String?,
    serial: String?
  ) throws -> BRLMChannel {
    let key = "\(type)|\(type == "wifi" ? (ip ?? "") : (type == "bluetooth" ? (mac ?? "") : (serial ?? "")))"
    if let cached = synchronized({ discoveredChannels[key] }) {
      return cached
    }
    switch type {
    case "wifi":
      guard let address = ip else {
        throw PluginFailure(code: "invalidArgument", message: "Indirizzo IP mancante")
      }
      return BRLMChannel(wifiIPAddress: address)
    case "bluetooth":
      // Il canale BLE si costruisce a partire dal nome pubblicizzato dal
      // dispositivo: per il Bluetooth è necessario passare una stampante
      // trovata con discoverPrinters().
      throw PluginFailure(
        code: "printerUnreachable",
        message: "Per il Bluetooth eseguire prima discoverPrinters e connettersi al risultato trovato"
      )
    case "usb":
      throw PluginFailure(code: "printerUnreachable", message: "USB non supportato su iOS")
    default:
      throw PluginFailure(code: "invalidArgument", message: "Tipo di connessione non supportato")
    }
  }

  private func disconnect() {
    synchronized {
      currentDriver?.closeChannel()
      currentDriver = nil
      currentModel = nil
    }
    emitState("disconnected")
  }

  // MARK: - Stampa

  private func printImage(_ call: FlutterMethodCall) throws -> [String: Any?] {
    let driver = try requireDriver()
    guard let args = call.arguments as? [String: Any] else {
      throw PluginFailure(code: "invalidArgument", message: "Argomenti mancanti")
    }
    guard let typedData = args["imageBytes"] as? FlutterStandardTypedData else {
      throw PluginFailure(code: "invalidArgument", message: "Bytes immagine mancanti")
    }
    guard let cgImage = Self.makeCGImage(from: typedData.data) else {
      throw PluginFailure(code: "invalidArgument", message: "Formato immagine non valido")
    }
    let options = (args["options"] as? [String: Any]) ?? [:]
    let error = driver.printImage(with: cgImage, settings: try createSettings(options))
    return printResultMap(error)
  }

  private func printPdf(_ call: FlutterMethodCall) throws -> [String: Any?] {
    let driver = try requireDriver()
    guard let args = call.arguments as? [String: Any] else {
      throw PluginFailure(code: "invalidArgument", message: "Argomenti mancanti")
    }
    guard let typedData = args["pdfBytes"] as? FlutterStandardTypedData else {
      throw PluginFailure(code: "invalidArgument", message: "Bytes PDF mancanti")
    }
    let options = (args["options"] as? [String: Any]) ?? [:]

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("brother_print_\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      try typedData.data.write(to: url)
    } catch {
      throw PluginFailure(code: "invalidArgument", message: "Impossibile scrivere il PDF temporaneo")
    }

    let error = driver.printPDF(with: url, settings: try createSettings(options))
    return printResultMap(error)
  }

  private func requireDriver() throws -> BRLMPrinterDriver {
    guard let driver = currentDriver else {
      throw PluginFailure(
        code: "printerUnreachable",
        message: "Nessuna stampante connessa: chiamare connect() prima di stampare"
      )
    }
    return driver
  }

  private func createSettings(_ options: [String: Any]) throws -> BRLMPrintSettingsProtocol {
    let copies = min(max((options["copies"] as? Int) ?? 1, 1), 99)
    let autoCut = (options["autoCut"] as? Bool) ?? true
    let paperType = options["paperType"] as? String

    guard let model = currentModel else {
      throw PluginFailure(code: "printerUnreachable", message: "Modello non impostato")
    }
    switch model {
    case .RJ_2050:
      guard let settings = BRLMRJPrintSettings(defaultPrintSettingsWith: .RJ_2050) else {
        throw PluginFailure(code: "unknown", message: "Impossibile creare RJPrintSettings")
      }
      settings.numCopies = UInt(copies)
      settings.scaleMode = .fitPageAspect
      applyCustomPaper(settings, options: options)
      return settings
    case .QL_820NWB:
      guard let settings = BRLMQLPrintSettings(defaultPrintSettingsWith: .QL_820NWB) else {
        throw PluginFailure(code: "unknown", message: "Impossibile creare QLPrintSettings")
      }
      settings.numCopies = UInt(copies)
      settings.autoCut = autoCut
      settings.scaleMode = .fitPageAspect
      if let paperType = paperType, let label = Self.labelSize(from: paperType) {
        settings.labelSize = label
      }
      return settings
    @unknown default:
      throw PluginFailure(code: "invalidArgument", message: "Modello non supportato")
    }
  }

  /// Imposta la custom paper size per la serie RJ.
  ///
  /// Per la serie RJ/TD la documentazione ufficiale Brother richiede di
  /// specificare la carta: per la RJ-2050 (2") si usa un rotolo da 2.0 inch
  /// con margini zero (vedi guida "Printing Image/PDF", sezione RJ/TD).
  private func applyCustomPaper(_ settings: BRLMRJPrintSettings, options: [String: Any]) {
    let margins = BRLMCustomPaperSizeMarginsMake(0, 0, 0, 0)
    if let widthMm = options["paperWidthMm"] as? Double, widthMm > 0 {
      settings.customPaperSize = BRLMCustomPaperSize(
        rollWithTapeWidth: CGFloat(widthMm),
        margins: margins,
        unitOfLength: .mm
      )
    } else {
      settings.customPaperSize = BRLMCustomPaperSize(
        rollWithTapeWidth: 2.0,
        margins: margins,
        unitOfLength: .inch
      )
    }
  }

  private func printResultMap(_ error: BRLMPrintError?) -> [String: Any?] {
    guard let error = error, error.code != .noError else {
      return ["success": true]
    }
    let code: String
    switch error.code {
    case .printerStatusErrorPaperEmpty:
      code = "outOfPaper"
    case .printerStatusErrorCoverOpen:
      code = "coverOpen"
    case .channelTimeout:
      code = "timeout"
    case .printerStatusErrorCommunicationError,
         .channelErrorStreamStatusError,
         .printerStatusErrorPrinterTurnedOff:
      code = "communicationLost"
    default:
      code = "unknown"
    }
    return [
      "success": false,
      "error": [
        "code": code,
        "message": error.errorDescription,
      ],
    ]
  }

  private func openChannelErrorCode(_ code: BRLMOpenChannelErrorCode) -> String {
    switch code {
    case .timeout: return "timeout"
    case .noError: return "unknown"
    default: return "communicationLost"
    }
  }

  // MARK: - Mappatura canali

  private static func channelKey(_ channel: BRLMChannel) -> String {
    let info = channel.extraInfo
    let ip = (info?[BRLMChannelExtraInfoKeyIpAddress] as? String) ?? ""
    let mac = (info?[BRLMChannelExtraInfoKeyMacAddress] as? String) ?? ""
    let serial = (info?[BRLMChannelExtraInfoKeySerialNumber] as? String) ?? ""
    switch channel.channelType {
    case .wiFi:
      return "wifi|\(ip)"
    case .bluetoothMFi, .bluetoothLowEnergy:
      return "bluetooth|\(mac)"
    @unknown default:
      return "usb|\(serial)"
    }
  }

  private func channelToMap(_ channel: BRLMChannel) -> [String: Any?] {
    let info = channel.extraInfo
    let rawModelName = (info?[BRLMChannelExtraInfoKeyModelName] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let modelName: String
    if let raw = rawModelName, !raw.isEmpty {
      modelName = raw
    } else {
      modelName = "Unknown"
    }
    let connectionType: String
    switch channel.channelType {
    case .wiFi:
      connectionType = "wifi"
    case .bluetoothMFi, .bluetoothLowEnergy:
      connectionType = "bluetooth"
    @unknown default:
      connectionType = "usb"
    }
    return [
      // Nome del modello riportato dall'SDK (es. "RJ-2050", "QL-820NWB").
      "model": modelName,
      "connectionType": connectionType,
      "ipAddress": (info?[BRLMChannelExtraInfoKeyIpAddress] as? String)
        ?? (channel.channelType == .wiFi ? channel.channelInfo : nil),
      "macAddress": info?[BRLMChannelExtraInfoKeyMacAddress] as? String,
      "serialNumber": (info?[BRLMChannelExtraInfoKeySerialNumber] as? String) ?? "",
    ]
  }

  private static func labelSize(from raw: String) -> BRLMQLPrintSettingsLabelSize? {
    switch raw {
    case "RollW62": return .rollW62
    case "RollW62RB": return .rollW62RB
    case "DieCutW62H100": return .dieCutW62H100
    case "DieCutW62H75": return .dieCutW62H75
    case "DieCutW62H60": return .dieCutW62H60
    case "DieCutW29H90": return .dieCutW29H90
    default: return nil
    }
  }

  // MARK: - Stato

  private func emitState(_ state: String) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(["state": state])
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    emitState(currentDriver != nil ? "connected" : "disconnected")
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Utility

  private func synchronized<T>(_ block: () -> T) -> T {
    objc_sync_enter(self)
    defer { objc_sync_exit(self) }
    return block()
  }

  private static func makeCGImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}

