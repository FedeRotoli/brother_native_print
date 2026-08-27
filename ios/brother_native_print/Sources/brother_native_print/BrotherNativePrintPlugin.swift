import CoreBluetooth
import Flutter
import Foundation
import ImageIO
import BRLMPrinterKit

// SDK class names verified against the BRLMPrinterKit.xcframework headers
// (BT_Net variant, for RJ-2050 and QL-820NWB which require Bluetooth).

/// Internal plugin error, converted to FlutterError at the channel boundary.
private struct PluginFailure: Error {
  let code: String
  let message: String
}

public class BrotherNativePrintPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  // Channels found in the last discovery, to reopen the connection.
  private var discoveredChannels: [String: BRLMChannel] = [:]
  // Logical connection: the physical channel is opened per operation, so the
  // printer is never left "busy" (Brother pattern: open -> operation -> close).
  private var connectedChannel: BRLMChannel?
  private var currentModel: BRLMPrinterModel?
  // Driver of the operation currently in flight (so cancelPrinting can reach
  // it from another thread while a print is stuck).
  private var currentDriver: BRLMPrinterDriver?
  private let queue = DispatchQueue(label: "brother_native_print.queue", qos: .userInitiated)

  // Discovery streaming
  private var discoveryEventSink: FlutterEventSink?
  // Bumped on every start/cancel to drop emissions from stale searches.
  private var discoveryGeneration = 0
  private let discoveryQueue = DispatchQueue(
    label: "brother_native_print.discovery",
    qos: .userInitiated,
    attributes: .concurrent
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "brother_native_print/methods",
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: "brother_native_print/status",
      binaryMessenger: registrar.messenger()
    )
    let discoveryChannel = FlutterEventChannel(
      name: "brother_native_print/discovery",
      binaryMessenger: registrar.messenger()
    )
    let instance = BrotherNativePrintPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    let discoveryHandler = DiscoveryStreamHandler()
    discoveryHandler.plugin = instance
    discoveryChannel.setStreamHandler(discoveryHandler)
  }

  /// Called when the engine detaches the plugin (hot restart, teardown).
  ///
  /// Closes the printer channel so the printer is not left "busy": Brother
  /// BLE/Bluetooth printers accept a single active connection, and if the
  /// channel stays open the printer stops being discoverable on the next run
  /// (same as Android's `onDetachedFromEngine`).
  public func detach(from registrar: FlutterPluginRegistrar) {
    synchronized {
      currentDriver?.closeChannel()
      currentDriver = nil
      connectedChannel = nil
      currentModel = nil
      discoveredChannels.removeAll()
    }
    cancelDiscovery()
    eventSink = nil
    discoveryEventSink = nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // cancelPrinting and disconnect must be serviced immediately, even while a
    // blocking print call is stuck on the serial queue: they abort the stuck
    // call / release the channel, so a stale print cannot block new
    // communication (which would cause a cascade of timeouts).
    if call.method == "cancelPrinting" || call.method == "disconnect" {
      if call.method == "cancelPrinting" {
        cancelPrinting()
      } else {
        disconnect()
      }
      DispatchQueue.main.async { result(nil) }
      return
    }
    queue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { result(FlutterError(code: "unknown", message: "Plugin released", details: nil)) }
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

  // MARK: - Methods

  private func handleSync(_ call: FlutterMethodCall) throws -> Any? {
    switch call.method {
    case "connect":
      return try connect(call)
    case "disconnect":
      disconnect()
      return nil
    case "printImage":
      return try printImage(call)
    case "printPdf":
      return try printPdf(call)
    case "getStatus":
      return try getStatus()
    default:
      return FlutterMethodNotImplemented
    }
  }

  // MARK: - Discovery (streaming)
  //
  // Discovery is exposed as a stream (`brother_native_print/discovery`
  // EventChannel): the already-paired classic Bluetooth printers are emitted
  // first (no waiting), then the Wi-Fi and BLE searches run in parallel on a
  // dedicated concurrent queue and each printer is pushed to the stream as
  // soon as it is found. The stream is closed with `FlutterEndOfEventStream`
  // when every requested search finishes. This avoids the old behaviour where
  // each blocking search ran sequentially for the whole timeout (~sum of the
  // timeouts).

  fileprivate func startDiscoveryStreaming(
    withArguments arguments: Any?,
    sink: @escaping FlutterEventSink
  ) {
    // Stop any in-flight discovery (also aborts the SDK scans).
    cancelDiscovery()

    discoveryGeneration += 1
    let generation = discoveryGeneration
    discoveryEventSink = sink

    let args = arguments as? [String: Any] ?? [:]
    let connectionTypes = (args["connectionTypes"] as? [String]) ?? ["wifi", "bluetooth"]
    let timeoutMs = (args["timeoutMs"] as? Int) ?? 10_000
    let duration = max(TimeInterval(timeoutMs) / 1000.0, 1.0)

    let group = DispatchGroup()

    // Fast path: already-paired classic Bluetooth devices are emitted
    // immediately, without waiting for the Wi-Fi/BLE scans.
    if connectionTypes.contains("bluetooth") {
      group.enter()
      discoveryQueue.async { [weak self] in
        defer { group.leave() }
        guard let self = self else { return }
        #if targetEnvironment(simulator)
        print("[BrotherNativePrint] WARNING: the iOS simulator does not support Bluetooth")
        #endif
        do { try self.ensureBluetoothAccess() } catch {
          print("[BrotherNativePrint] Bluetooth access denied: \(error.localizedDescription)")
          return
        }
        let result = BRLMPrinterSearcher.startBluetoothSearch()
        if result.error.code == .noError {
          result.channels.forEach { self.emitChannel($0, generation: generation) }
        } else {
          print("[BrotherNativePrint] Classic Bluetooth search failed: \(result.error.code.rawValue)")
        }
      }
    }

    if connectionTypes.contains("wifi") {
      group.enter()
      discoveryQueue.async { [weak self] in
        defer { group.leave() }
        guard let self = self else { return }
        let option = BRLMNetworkSearchOption()
        option.searchDuration = duration
        let result = BRLMPrinterSearcher.startNetworkSearch(option) { channel in
          self.emitChannel(channel, generation: generation)
        }
        if result.error.code != .noError {
          print("[BrotherNativePrint] Wi-Fi search failed: \(result.error.code.rawValue)")
        }
      }
    }

    if connectionTypes.contains("bluetooth") {
      group.enter()
      discoveryQueue.async { [weak self] in
        defer { group.leave() }
        guard let self = self else { return }
        #if targetEnvironment(simulator)
        print("[BrotherNativePrint] WARNING: the iOS simulator does not support Bluetooth")
        #endif
        do { try self.ensureBluetoothAccess() } catch {
          print("[BrotherNativePrint] Bluetooth access denied: \(error.localizedDescription)")
          return
        }
        let option = BRLMBLESearchOption()
        option.searchDuration = duration
        let result = BRLMPrinterSearcher.startBLESearch(option) { channel in
          self.emitChannel(channel, generation: generation)
        }
        if result.error.code != .noError {
          print("[BrotherNativePrint] BLE search failed: \(result.error.code.rawValue)")
        }
      }
    }

    // USB is not supported by the iOS kit: it always returns an empty list.

    group.notify(queue: .main) { [weak self] in
      self?.endDiscovery(generation: generation)
    }
  }

  private func emitChannel(_ channel: BRLMChannel, generation: Int) {
    guard generation == discoveryGeneration else { return }
    let key = Self.channelKey(channel)
    let shouldEmit = synchronized { () -> Bool in
      if discoveredChannels[key] != nil { return false }
      discoveredChannels[key] = channel
      return true
    }
    guard shouldEmit else { return }
    let map = channelToMap(channel)
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.discoveryGeneration == generation else { return }
      self.discoveryEventSink?(map)
    }
  }

  private func endDiscovery(generation: Int) {
    guard generation == discoveryGeneration else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.discoveryGeneration == generation else { return }
      self.discoveryEventSink?(FlutterEndOfEventStream)
      self.discoveryEventSink = nil
    }
  }

  fileprivate func cancelDiscovery() {
    discoveryGeneration += 1
    discoveryEventSink = nil
    // Make the blocking SDK searches return early instead of waiting the
    // full timeout.
    BRLMPrinterSearcher.cancelNetworkSearch()
    BRLMPrinterSearcher.cancelBLESearch()
  }

  private func ensureBluetoothAccess() throws {
    // iOS 13.1+: user Bluetooth authorization.
    if #available(iOS 13.1, *) {
      switch CBManager.authorization {
      case .denied, .restricted:
        throw PluginFailure(
          code: "permissionMissing",
          message: "Bluetooth access denied: enable it in the settings"
        )
      default:
        break
      }
    }
  }

  // MARK: - Connection

  private func connect(_ call: FlutterMethodCall) throws -> Bool {
    guard let args = call.arguments as? [String: Any] else {
      throw PluginFailure(code: "invalidArgument", message: "Missing connection arguments")
    }
    guard let modelName = args["model"] as? String else {
      throw PluginFailure(code: "invalidArgument", message: "Missing 'model' field")
    }
    let model: BRLMPrinterModel
    if modelName.caseInsensitiveCompare("RJ-2050") == .orderedSame {
      model = .RJ_2050
    } else if modelName.caseInsensitiveCompare("QL-820NWB") == .orderedSame {
      model = .QL_820NWB
    } else {
      throw PluginFailure(code: "invalidArgument", message: "Unsupported model: \(modelName)")
    }
    guard let connectionType = args["connectionType"] as? String else {
      throw PluginFailure(code: "invalidArgument", message: "Missing 'connectionType' field")
    }
    let ip = args["ipAddress"] as? String
    let mac = args["macAddress"] as? String
    let serial = args["serialNumber"] as? String

    let channel = try resolveChannel(type: connectionType, ip: ip, mac: mac, serial: serial)

    // Reachability probe: open and immediately close a channel. The actual
    // data operations open their own channel per call and close it afterwards
    // (Brother pattern: open -> operation -> close), so the printer is never
    // left "busy" by a stale session.
    let probe = BRLMPrinterDriverGenerator.open(channel)
    if probe.error.code != .noError {
      throw PluginFailure(
        code: openChannelErrorCode(probe.error.code),
        message: probe.error.errorRecoverySuggestion ?? "Unable to open the channel"
      )
    }
    probe.driver?.closeChannel()

    synchronized {
      connectedChannel = channel
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
        throw PluginFailure(code: "invalidArgument", message: "Missing IP address")
      }
      return BRLMChannel(wifiIPAddress: address)
    case "bluetooth":
      // The BLE channel is built from the name advertised by the device: for
      // Bluetooth you must pass a printer found with discoverPrinters().
      throw PluginFailure(
        code: "printerUnreachable",
        message: "For Bluetooth, call discoverPrinters first and connect to a found printer"
      )
    case "usb":
      throw PluginFailure(code: "printerUnreachable", message: "USB is not supported on iOS")
    default:
      throw PluginFailure(code: "invalidArgument", message: "Unsupported connection type")
    }
  }

  /// Opens the stored channel and returns a fresh driver for this operation.
  private func openDriver() throws -> BRLMPrinterDriver {
    guard let channel = synchronized({ connectedChannel }) else {
      throw PluginFailure(
        code: "printerUnreachable",
        message: "No printer connected: call connect() first"
      )
    }
    let openResult = BRLMPrinterDriverGenerator.open(channel)
    guard openResult.error.code == .noError else {
      throw PluginFailure(
        code: openChannelErrorCode(openResult.error.code),
        message: openResult.error.errorRecoverySuggestion ?? "Unable to open the channel"
      )
    }
    guard let driver = openResult.driver else {
      throw PluginFailure(code: "communicationLost", message: "Driver not available")
    }
    return driver
  }

  /// Runs [body] on a fresh driver and ALWAYS closes the channel afterwards
  /// (also on failure), so the printer is never left "busy" by a stale session.
  private func withDriver<T>(_ body: (BRLMPrinterDriver) throws -> T) throws -> T {
    let driver = try openDriver()
    synchronized { currentDriver = driver }
    defer {
      synchronized { currentDriver = nil }
      driver.closeChannel()
    }
    return try body(driver)
  }

  private func disconnect() {
    synchronized {
      // Request an abort of any in-flight operation (safe: it only sets the
      // SDK flag; the operation closes its own channel on return).
      currentDriver?.cancelPrinting()
      connectedChannel = nil
      currentModel = nil
    }
    emitState("disconnected")
  }

  /// Asks the SDK to abort any in-flight print (sets the SDK cancel flag).
  /// Safe to call from any thread while a print is stuck.
  private func cancelPrinting() {
    synchronized { currentDriver }?.cancelPrinting()
  }

  // MARK: - Stampa

  private func printImage(_ call: FlutterMethodCall) throws -> [String: Any?] {
    guard let args = call.arguments as? [String: Any] else {
      throw PluginFailure(code: "invalidArgument", message: "Missing arguments")
    }
    guard let typedData = args["imageBytes"] as? FlutterStandardTypedData else {
      throw PluginFailure(code: "invalidArgument", message: "Missing image bytes")
    }
    guard let cgImage = Self.makeCGImage(from: typedData.data) else {
      throw PluginFailure(code: "invalidArgument", message: "Invalid image format")
    }
    let options = (args["options"] as? [String: Any]) ?? [:]
    let model = try requireModel()
    return try withDriver { driver in
      let error = driver.printImage(with: cgImage, settings: try createSettings(options, model: model))
      return printResultMap(error)
    }
  }

  private func printPdf(_ call: FlutterMethodCall) throws -> [String: Any?] {
    guard let args = call.arguments as? [String: Any] else {
      throw PluginFailure(code: "invalidArgument", message: "Missing arguments")
    }
    guard let typedData = args["pdfBytes"] as? FlutterStandardTypedData else {
      throw PluginFailure(code: "invalidArgument", message: "Missing PDF bytes")
    }
    let options = (args["options"] as? [String: Any]) ?? [:]
    let model = try requireModel()

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("brother_print_\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      try typedData.data.write(to: url)
    } catch {
      throw PluginFailure(code: "invalidArgument", message: "Unable to write the temporary PDF")
    }

    return try withDriver { driver in
      let error = driver.printPDF(with: url, settings: try createSettings(options, model: model))
      return printResultMap(error)
    }
  }

  private func requireModel() throws -> BRLMPrinterModel {
    guard let model = synchronized({ currentModel }) else {
      throw PluginFailure(
        code: "printerUnreachable",
        message: "No printer connected: call connect() before printing"
      )
    }
    return model
  }

  private func createSettings(_ options: [String: Any], model: BRLMPrinterModel) throws -> BRLMPrintSettingsProtocol {
    let copies = min(max((options["copies"] as? Int) ?? 1, 1), 99)
    let autoCut = (options["autoCut"] as? Bool) ?? true
    let paperType = options["paperType"] as? String

    switch model {
    case .RJ_2050:
      guard let settings = BRLMRJPrintSettings(defaultPrintSettingsWith: .RJ_2050) else {
        throw PluginFailure(code: "unknown", message: "Unable to create RJPrintSettings")
      }
      settings.numCopies = UInt(copies)
      settings.scaleMode = .fitPageAspect
      // Over Bluetooth the pre-print status request can fail
      // ("Failed to get status") on some RJ models: skip it.
      settings.skipStatusCheck = true
      applyCustomPaper(settings, options: options)
      return settings
    case .QL_820NWB:
      guard let settings = BRLMQLPrintSettings(defaultPrintSettingsWith: .QL_820NWB) else {
        throw PluginFailure(code: "unknown", message: "Unable to create QLPrintSettings")
      }
      settings.numCopies = UInt(copies)
      settings.autoCut = autoCut
      settings.scaleMode = .fitPageAspect
      settings.skipStatusCheck = true
      if let paperType = paperType, let label = Self.labelSize(from: paperType) {
        settings.labelSize = label
      }
      return settings
    @unknown default:
      throw PluginFailure(code: "invalidArgument", message: "Unsupported model")
    }
  }

  /// Applies the custom paper size for the RJ series.
  ///
  /// For the RJ/TD series the official Brother documentation requires the
  /// paper to be specified: for the RJ-2050 (2") a 2.0 inch roll with 2 mm
  /// side margins is used (RJ Utility's 58 mm RJ profile).
  private func applyCustomPaper(_ settings: BRLMRJPrintSettings, options: [String: Any]) {
    // If the app provided a .bin file (Brother Paper Size Setup Tool), use
    // it: it is the most reliable paper definition for the connected printer.
    if let binPath = options["paperBinPath"] as? String, !binPath.isEmpty {
      settings.customPaperSize = BRLMCustomPaperSize(file: URL(fileURLWithPath: binPath))
      return
    }
    // Aligned with Android: margins top=3, left=2, bottom=3, right=2 (mm) and
    // a default 58 mm roll. With 2 mm on each side the printable area becomes
    // 54 mm (RJ-2050 printhead: 432 dots at 203 dpi).
    let margins = BRLMCustomPaperSizeMarginsMake(3, 2, 3, 2)
    if let widthMm = options["paperWidthMm"] as? Double, widthMm > 0 {
      settings.customPaperSize = BRLMCustomPaperSize(
        rollWithTapeWidth: CGFloat(widthMm),
        margins: margins,
        unitOfLength: .mm
      )
    } else {
      settings.customPaperSize = BRLMCustomPaperSize(
        rollWithTapeWidth: 58.0,
        margins: margins,
        unitOfLength: .mm
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

  // MARK: - Printer hardware status

  /// Queries the SDK for the current hardware status, or nil if disconnected.
  private func getStatus() throws -> [String: Any?]? {
    guard synchronized({ connectedChannel }) != nil else { return nil }
    return try withDriver { driver in
      let result = driver.getPrinterStatus()
      if result.error.code != .noError {
        // The status query itself failed (timeout / printer not found).
        let code: String
        switch result.error.code {
        case .timeout: code = "timeout"
        case .printerNotFound: code = "printerUnreachable"
        @unknown default: code = "unknown"
        }
        return [
          "isOk": false,
          "errorCode": code,
          "mediaWidthMm": 0,
          "mediaHeightMm": 0,
          "isHeightInfinite": false,
        ]
      }
      guard let status = result.status else {
        return [
          "isOk": false, "errorCode": "unknown",
          "mediaWidthMm": 0, "mediaHeightMm": 0, "isHeightInfinite": false,
        ]
      }
      let mediaInfo = status.mediaInfo
      // The exact QL label size the printer detected (e.g. "RollW62",
      // "DieCutW62H100"): pass it as paperType to avoid "wrong roll type".
      var detectedPaperType: String?
      if let media = mediaInfo {
        var succeeded = false
        let size = media.getQLLabelSize(&succeeded)
        if succeeded {
          detectedPaperType = qlLabelSizeName(size)
        }
      }
      return [
        "isOk": status.errorCode == .noError,
        "errorCode": statusErrorCodeName(status.errorCode),
        "mediaWidthMm": mediaInfo?.width_mm ?? 0,
        "mediaHeightMm": mediaInfo?.height_mm ?? 0,
        "isHeightInfinite": mediaInfo?.isHeightInfinite ?? false,
        "detectedPaperType": detectedPaperType,
      ]
    }
  }

  /// Converts a [BRLMQLPrintSettingsLabelSize] to the same string used by
  /// [labelSize(from:)] / `PrintOptions.paperType`.
  private func qlLabelSizeName(_ size: BRLMQLPrintSettingsLabelSize) -> String? {
    switch size {
    case .dieCutW17H54: return "DieCutW17H54"
    case .dieCutW17H87: return "DieCutW17H87"
    case .dieCutW23H23: return "DieCutW23H23"
    case .dieCutW29H42: return "DieCutW29H42"
    case .dieCutW29H90: return "DieCutW29H90"
    case .dieCutW38H90: return "DieCutW38H90"
    case .dieCutW39H48: return "DieCutW39H48"
    case .dieCutW52H29: return "DieCutW52H29"
    case .dieCutW62H29: return "DieCutW62H29"
    case .dieCutW62H60: return "DieCutW62H60"
    case .dieCutW62H75: return "DieCutW62H75"
    case .dieCutW62H100: return "DieCutW62H100"
    case .dieCutW60H86: return "DieCutW60H86"
    case .dieCutW54H29: return "DieCutW54H29"
    case .dieCutW102H51: return "DieCutW102H51"
    case .dieCutW102H152: return "DieCutW102H152"
    case .dieCutW103H164: return "DieCutW103H164"
    case .rollW12: return "RollW12"
    case .rollW29: return "RollW29"
    case .rollW38: return "RollW38"
    case .rollW50: return "RollW50"
    case .rollW54: return "RollW54"
    case .rollW62: return "RollW62"
    case .rollW62RB: return "RollW62RB"
    case .rollW102: return "RollW102"
    case .rollW103: return "RollW103"
    // The DT and Round variants belong to other printer series (not the
    // QL-820NWB), so they are not mapped individually: report null.
    default: return nil
    }
  }

  private func statusErrorCodeName(_ code: BRLMPrinterStatusErrorCode) -> String? {
    switch code {
    case .noError: return nil
    case .noPaper: return "outOfPaper"
    case .coverOpen: return "coverOpen"
    case .busy: return "busy"
    case .paperJam: return "paperJam"
    case .batteryEmpty: return "batteryEmpty"
    case .batteryTrouble: return "batteryTrouble"
    case .tubeNotDetected: return "tubeNotDetected"
    case .motorSlow: return "motorSlow"
    case .unsupportedCharger: return "unsupportedCharger"
    case .incompatibleOptionalEquipment: return "incompatibleEquipment"
    case .systemError: return "systemError"
    case .anotherError: return "anotherError"
    @unknown default: return "unknown"
    }
  }

  private func openChannelErrorCode(_ code: BRLMOpenChannelErrorCode) -> String {
    switch code {
    case .timeout: return "timeout"
    case .noError: return "unknown"
    default: return "communicationLost"
    }
  }

  // MARK: - Channel mapping

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
      // Model name as reported by the SDK (e.g. "RJ-2050", "QL-820NWB").
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

/// Stream handler for the discovery channel: starts the streaming discovery
/// when a listener subscribes and stops it when the listener cancels.
private class DiscoveryStreamHandler: NSObject, FlutterStreamHandler {
  weak var plugin: BrotherNativePrintPlugin?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    plugin?.startDiscoveryStreaming(withArguments: arguments, sink: events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    plugin?.cancelDiscovery()
    return nil
  }
}

