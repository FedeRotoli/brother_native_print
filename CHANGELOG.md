## 0.6.2

- **Docs (README)**: added a *Publishing to the Apple Store* section to the
  README documenting that apps submitting to the App Store and connecting to
  Brother printers over Bluetooth/BLE must first obtain a **PPID (Program
  Product Identifier) from Brother** — a mandatory step for Apple's **MFi**
  program. The section links to Brother's MFi request page
  (<https://secure6.brother.co.jp/mfi/Top.aspx>) and quotes the rejection
  message ("App has not been authorized by the accessory manufacturer to work
  with the MFi accessory") the developer will otherwise receive.

## 0.6.1

- **Enhancement (Android & iOS)**: Wi-Fi discovery now reports the printer
  serial number. The unicast subnet sweep queries the Brother private MIB
  serial OID (`1.3.6.1.4.1.2435.2.3.9.4.2.1.5.5.1.0`, the same one the SDK
  network search reads) and populates the channel serial, so
  `BrotherPrinter.serialNumber` is filled for printers found over Wi-Fi (both
  via the SDK search and the sweep). Bluetooth/BLE still do not expose it.
- **Enhancement (API)**: `BrotherNativePrint.connect()` accepts a
  `resolveSerialNumber` flag (default `true`). Set it to `false` to skip the
  serial-number round-trip over the just-opened connection and speed up the
  connection when the serial is not needed.

## 0.6.0

- **Fix (Android & iOS)**: discovery no longer reports non-Brother devices as
  Brother printers. The Bluetooth/BLE searches also return arbitrary devices
  (paired phones, headphones, other BLE peripherals...): they are now filtered
  out in `emitChannel`, keeping only devices whose advertised name contains the
  "Brother" brand or a Brother label-printer model token (`QL-`, `RJ-`, `TD-`,
  `PT-`, `PJ-`, `MW-` followed by digits).

## 0.5.1

- **Fix (iOS)**: the bundled `BRLMPrinterKit.xcframework` is now ad-hoc
  re-signed and its `.swiftinterface` headers are normalized to LF line
  endings. The previous release shipped an unsigned framework whose
  interfaces used CRLF, which Xcode 26 / Swift 6.3.3 fails to parse (error
  reading `swift-interface-format-version`) and can trip stricter
  framework-validation checks.
- **Fix (iOS)**: fixed a compile error in `BrotherNativePrintPlugin.swift`
  where `requestSerialNumber()` (BRLMPrinterKit 4.13.0) returns a non-Optional
  result and can no longer be used in an `if let` binding.

## 0.5.0

- **Fix (Android & iOS)**: the serial number was empty for printers found over
  Bluetooth and Wi-Fi. The SDK only populates the serial in the discovery
  channel's extra info for USB (and sometimes MFi Bluetooth), so the plugin now
  queries the real serial over the active connection while connecting
  (`requestSerialNumber()` on Android / `BRLMPrinterDriver` on iOS) and
  persists it in the connected printer returned by `getConnectedPrinter()`.
  The example app refreshes the selected printer after connect to display it.
- **Fix (Android & iOS)**: the MAC address now shows up wherever the platform
  can report it. On Wi-Fi the unicast subnet sweep probes `ifPhysAddress` via
  SNMP (same OID the SDK network search uses), so network printers found by
  the sweep also carry a MAC; on Android, classic Bluetooth printers report
  their device address as the MAC (the SDK leaves the extra-info MAC empty but
  stores the address as the channel info). BLE MAC stays `null` (the OS hides
  it for privacy on both platforms).

## 0.4.2

- **Fix (Android & iOS)**: the printer model is now extracted (normalized)
  instead of exact-matched when connecting. Some Brother printers report their
  Bluetooth device name — model plus a 4-digit identifier, e.g.
  `QL-820NWB1234` — as the model, which previously failed with an
  "Unsupported model" exception on connect. Discovery now also reports the
  canonical model (e.g. `QL-820NWB`) for such devices.

## 0.4.1

- **Fix (Android)**: discovery and status events are now emitted on the main
  thread. Flutter requires `EventChannel.EventSink` calls (`success`, `error`,
  `endOfStream`) to run on the Android main thread, but discovery streamed
  channels, ended the stream and emitted status changes from background
  threads (`Dispatchers.IO`, SDK discovery callbacks, unicast sweep threads),
  crashing the app with "Methods marked with @UiThread must be executed on the
  main thread". Events are now routed through a main-thread `Handler`;
  `MethodChannel` results are unchanged (the engine documents them as safe to
  call from any thread).

## 0.4.0

- **More reliable Wi-Fi discovery (unicast subnet sweep)**:
  the SDK's network search relies on a broadcast that some routers filter and
  that some printer firmware ignores, so it could report 0 printers even when
  the phone and the printer were on the same healthy network. The plugin now
  also probes every host on the phone's subnet directly (unicast SNMP, same
  MIB the SDK uses) and reports printers as they are found — on Android and
  iOS.
- **Discovery reports Brother printers only**: the SNMP model is normalized
  and non-Brother devices are filtered out, so other network printers no
  longer appear in the Wi-Fi results.
- **Fix**: the SNMP response parser now reads the value inside the GetResponse
  PDU, so the printer model is extracted correctly (an unsupported OID could
  previously report the SNMP community — "public" — or nothing as the model).
- **Example**: the search button now opens a channel picker (Wi-Fi / Bluetooth
  / USB) before scanning, and the "Connect by IP" button was removed.

## 0.3.0

- **New API `getConnectedPrinter()`**: returns the printer currently connected
  (model, connection type, IP/MAC address, serial number) or `null` when none.
  The logical connection is kept until `disconnect()` (or plugin detach), so
  the app can recover it on any screen and print again without re-running
  discovery — useful because a printer connected without a proper disconnect
  is often still "busy" and no longer listed by the discovery.
- **Status stream now reports the stored connection**: subscribing to
  `statusStream` after the connection was established (e.g. after navigating
  to another screen) previously reported `disconnected` because it inspected
  the transient in-flight driver instead of the stored logical connection.
- **Example**: `PrinterController` restores the connection from
  `getConnectedPrinter()` when the screen is (re)created, so returning to the
  screen after connecting elsewhere keeps the printer selected and ready.

## 0.2.0

- **Robust connection management**: the native side now follows the Brother
  pattern `open → operation → close` and opens a fresh channel for every status
  query and print job, always closing it afterwards (also on failure). This
  fixes printers (notably the QL-820NWB over Bluetooth/BLE) reporting "busy"
  and becoming unreachable after the first command: they accept a single
  active connection, which was being left open. `connect()` validates
  reachability (open + close probe) and keeps the logical connection, while
  `getPrinterStatus()` / `printImage()` / `printPdf()` open and close their
  own channel.
- **Android**: every SDK driver call now runs on a dedicated single thread,
  satisfying the SDK requirement ("Methods MUST be called on a single
  thread") and preventing a status query that outlives its timeout from
  overlapping the next print.
- **New API `getPrinterStatus()`**: queries the hardware status of the
  connected printer, returning a normalized `PrinterHardwareStatus` (error
  state, detected media size, and the exact QL label size detected — pass it
  as `paperType` to avoid the "wrong roll type" error).
- **New API `cancelPrinting()`**: asks the SDK to abort any in-flight print,
  releasing the channel so a stale print cannot block new communication.
- **New `BrotherPrintPresets`**: ready-to-use `PrintOptions` presets for the
  configurations validated on hardware (QL-820NWB die-cut 29×90 mm, QL-820NWB
  roll 62 mm, RJ-2050 roll 58 mm), with `forMedia()` to match the cassette
  actually loaded in the printer.
- **iOS**: `detach(from:)` now closes the printer channel so the printer is
  not left "busy" after a hot restart, and `disconnect()` no longer touches
  the SDK driver directly.
- **Example**: reorganized into a clean folder structure (screens, services,
  labels) with a `PrinterController` owning the plugin logic; the detected
  label size is cached per connection so printing does not run a status query
  before every job.

## 0.1.1

- **Faster discovery**: `discoverPrinters()` now streams results through a new
  `discoverPrintersStream()` API. Already-paired Bluetooth printers are
  reported immediately and the Wi-Fi/BLE/USB searches run in parallel (total
  time is ~max of the timeouts instead of their sum), so discovery completes
  in ~10s instead of ~20s and printers appear in the UI as they are found.

## 0.1.0

- Initial public release.
- Discover Brother printers over Wi-Fi, Bluetooth (BLE + classic SPP) and USB
  (Android).
- Connect to a printer and observe connection state via
  `Stream<PrinterStatus>`.
- Print images (PNG/JPEG) and PDFs with configurable copies, paper type,
  auto-cut and custom paper size (including `.bin` custom paper files).
- Custom paper `.bin` definitions for the supported RJ/TD models are bundled
  with the package as assets and exposed through the `BrotherCustomPaper`
  helper, so applications don't need to copy them.
- Normalized, platform-independent error codes via `BrotherPrintErrorCode`.
- Tested with the RJ-2050 and QL-820NWB printers.
