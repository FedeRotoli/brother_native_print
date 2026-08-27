# brother_native_print

A Flutter plugin for printing **images** and **PDFs** to Brother label and
mobile printers over **Wi-Fi**, **Bluetooth / BLE** and **USB (Android only)**.

[![pub package](https://img.shields.io/pub/v/brother_native_print.svg)](https://pub.dev/packages/brother_native_print)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Built on top of the official Brother SDKs:

- **Android** – [Brother Print SDK for Android](https://support.brother.com/)
  (`com.brother.sdk.lmprinter`), bundled as a local Maven AAR.
- **iOS** – BRLMPrinterKit (BT_Net variant), bundled as a binary **xcframework**
  and distributed via **Swift Package Manager** (no CocoaPods).

## Features

- Discover Brother printers over Wi-Fi, Bluetooth (BLE + classic SPP) and USB
  (Android).
- Connect to a printer and keep track of its connection state through a
  `Stream<PrinterStatus>`.
- Print **images** (PNG/JPEG) and **PDFs** with configurable options:
  copies, paper type, auto-cut and custom paper size.
- Normalized, platform-independent error codes (`BrotherPrintErrorCode`).
- No model filtering during discovery: every compatible Brother printer that
  the SDK reports is returned.

## Supported printers

Discovery shows **all** compatible Brother printers found on the network or via
Bluetooth, regardless of model.

Printing is implemented and tested on:

| Model | Series | Notes |
| --- | --- | --- |
| **RJ-2050** | Mobile / receipt | 2" roll, custom paper support |
| **QL-820NWB** | Label | Label sizes, auto-cut |

Calling `connect()` with a different model returns `invalidArgument`.

## Platforms

| Platform | Support |
| --- | --- |
| Android | ✅ Wi-Fi, Bluetooth/BLE, USB |
| iOS | ✅ Wi-Fi, Bluetooth/BLE (via discovery; no USB) |

## Installation

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  brother_native_print: ^0.1.0
```

Then run `flutter pub get`.

## Platform setup

### Android

The Brother SDK is published in the plugin's local Maven repository
(`android/maven-repo`). AGP 9 no longer supports direct local `.aar`
dependencies when building an AAR, so the host app must register that
repository. Add this to your app's `android/build.gradle.kts`:

```kotlin
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("$rootDir/<path-to-plugin>/android/maven-repo") }
    }
}
```

Declare the required permissions in your app's `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
```

On Android 12+ you must also request the runtime permissions
(`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`) **before** calling
`discoverPrinters()` (the example app uses
[`permission_handler`](https://pub.dev/packages/permission_handler) for this).

### iOS

1. Enable Swift Package Manager support:
   `flutter config --enable-swift-package-manager`
2. Add the following keys to your `ios/Runner/Info.plist`:

   ```xml
   <key>NSBluetoothAlwaysUsageDescription</key>
   <string>Used to search for and connect to Brother printers over Bluetooth.</string>
   <key>NSBluetoothPeripheralUsageDescription</key>
   <string>Used to search for and connect to Brother printers over Bluetooth.</string>
   <key>NSLocalNetworkUsageDescription</key>
   <string>Used to search for Brother printers on your local network.</string>
   <key>NSBonjourServices</key>
   <array>
       <string>_ipp._tcp</string>
       <string>_printer._tcp</string>
       <string>_pdl-datastream._tcp</string>
   </array>
   <key>UISupportedExternalAccessoryProtocols</key>
   <array>
       <string>com.brother.ptcbp</string>
   </array>
   ```

## Quick start

```dart
import 'package:brother_native_print/brother_native_print.dart';

final plugin = BrotherNativePrint();

// Discover printers (Wi-Fi + Bluetooth by default).
final printers = await plugin.discoverPrinters();

// Or stream printers as soon as they are found: already-paired Bluetooth
// printers arrive first, Wi-Fi/BLE results follow as the scans complete.
final stream = plugin.discoverPrintersStream();
await for (final printer in stream) {
  print('Found ${printer.model} (${printer.connectionType.name})');
}

// Connect to a printer.
await plugin.connect(printers.first);

// Observe connection state.
plugin.statusStream.listen((status) => print(status.state));

// Print an image (PNG/JPEG bytes).
final imageResult = await plugin.printImage(imageBytes);

// Print a PDF (raw bytes).
final pdfResult = await plugin.printPdf(pdfBytes);

// Disconnect.
await plugin.disconnect();
```

### Cancelling a stuck print

If a print hangs (e.g. the SDK never receives the end-of-print confirmation
over a slow Bluetooth/BLE link), abort it with `cancelPrinting()` so the
channel is released and a new print can be attempted:

```dart
// e.g. after a timeout:
await plugin.cancelPrinting();
```

`cancelPrinting()` is serviced immediately by the native side, even while the
blocking print call is still running, so it can unblock a stale print. You can
also call `disconnect()` at any time to release the connection.

### Printing options

`PrintOptions` supports:

| Option | Description |
| --- | --- |
| `copies` | Number of copies (default `1`). |
| `paperType` | Label size, mainly for QL-820NWB (e.g. `RollW62`). When `null`, the SDK default is used. |
| `autoCut` | Auto-cut after printing (QL models only, default `true`). |
| `paperWidthMm` | Roll width in mm for custom paper (RJ models, default `58`). |
| `paperBinPath` | Path (on device) to a `.bin` custom paper definition generated with Brother Paper Size Setup Tool. Takes precedence over `paperWidthMm`. |

### Presets

Instead of remembering SDK paper codes and roll widths, use the bundled
[`BrotherPrintPresets`](https://pub.dev/documentation/brother_native_print/latest/brother_native_print/BrotherPrintPresets-class.html)
templates for the configurations validated on real hardware:

| Preset | Model | Paper |
| --- | --- | --- |
| `ql820NwbDieCut29x90` | QL-820NWB | Die-cut 29×90 mm (`DieCutW29H90`) |
| `ql820NwbRoll62` | QL-820NWB | Roll 62 mm (`RollW62`) |
| `rj2050Roll58` | RJ-2050 | Roll 58 mm (`paperWidthMm: 58`) |

Each preset maps to `PrintOptions` via `toOptions()` and reports the label
pixel size (at the printer's dpi) with `imageSize()`, useful to render the
image to print:

```dart
// QL-820NWB with the 29×90 mm die-cut cassette.
final options = BrotherPrintPresets.ql820NwbDieCut29x90.toOptions();
final result = await plugin.printImage(imageBytes, options: options);

// Size the preview bitmap (343×1063 at 300 dpi).
final size = BrotherPrintPresets.ql820NwbDieCut29x90.imageSize();
```

Presets are only a convenience: for any other label, build a `PrintOptions`
with custom values as usual.

#### Auto-detecting the loaded label

To avoid the printer's "wrong roll type" error, match the preset to the
cassette actually loaded in the printer by combining `getPrinterStatus()` with
`forMedia()`:

```dart
final status = await plugin.getPrinterStatus();
if (status != null) {
  final preset = BrotherPrintPresets.forMedia(status);
  if (preset != null) {
    final result = await plugin.printImage(
      imageBytes,
      options: preset.toOptions(),
    );
  }
}
```

### Custom paper (RJ series)

RJ printers require an explicit paper definition. If the roll is not
recognized by the SDK (e.g. third-party rolls), use a custom paper size:

- provide a `.bin` file (generated with **Brother Paper Size Setup Tool**)
  via `paperBinPath`, or
- set the roll width via `paperWidthMm` (the plugin applies the default
  margins: top/right/bottom/left = 3/2/3/2 mm).

#### Bundled custom papers

The package **ships the custom paper `.bin` files** for the supported RJ/TD
models as package assets, so applications don't have to copy them. Use the
[`BrotherCustomPaper`](https://pub.dev/documentation/brother_native_print/latest/brother_native_print/BrotherCustomPaper-class.html)
helper to resolve and extract one:

```dart
// Loads the bundled RJ-2050 58mm custom paper into a temp file
// and returns its path (for PrintOptions.paperBinPath).
final binPath = await BrotherCustomPaper.binPathFor(
  model: 'RJ-2050',
  widthMm: 58,
);

final result = await plugin.printImage(
  imageBytes,
  options: PrintOptions(paperBinPath: binPath),
);
```

`assetPathFor()` returns the matching `packages/brother_native_print/...` asset
path without extracting, and `copyToFile()` copies any of the bundled assets to
a temporary file. If the model/width you need doesn't follow the
`<Model>-RD<width>mm.bin` naming convention, pick the exact file from the
`custom_paper/` folder of the package and pass its asset path to `copyToFile()`.

### Errors

Printing errors are normalized to `BrotherPrintErrorCode`:

```dart
final result = await plugin.printImage(imageBytes);
if (!result.success) {
  switch (result.error!.code) {
    case BrotherPrintErrorCode.outOfPaper:
      // Handle out-of-paper...
    case BrotherPrintErrorCode.communicationLost:
      // Handle communication loss...
    default:
      break;
  }
}
```

### Printer status

To diagnose print failures (out of paper, cover open, wrong label size, or a
printer that does not respond), query the hardware status on demand with
`getPrinterStatus()`:

```dart
final status = await plugin.getPrinterStatus(); // null when disconnected
if (status != null) {
  print('ok: ${status.isOk}, error: ${status.errorCode}');
  print('media: ${status.mediaWidthMm} x ${status.mediaHeightMm} mm'
      ' (roll: ${status.isHeightInfinite})');
}
```

`PrinterHardwareStatus` reports the SDK error state (`isOk` / `errorCode`) and
the media the printer actually detected (`mediaWidthMm`, `mediaHeightMm`,
`isHeightInfinite`), which is useful to spot a label size mismatch.

### Recovering the current connection

To check whether a printer is already connected and recover its data (model,
IP/MAC address, serial number) on any screen — e.g. after navigating within
the app or returning after the connection was established — use
`getConnectedPrinter()`:

```dart
final BrotherPrinter? printer = await plugin.getConnectedPrinter();
if (printer != null) {
  // Already connected: print again without re-running discovery.
  await plugin.printImage(imageBytes);
} else {
  // Nothing connected: run discovery and connect() first.
}
```

The logical connection is kept until `disconnect()` (or the plugin is
detached), so this works even when the printer is not listed by a new
discovery — a printer connected without a proper disconnect is often still
"busy" and no longer discoverable. `statusStream` also reports the stored
connection as soon as you subscribe, so a screen created after the connection
was established sees `connected` immediately.

## Connection model

The native plugin follows the Brother-recommended pattern **`open channel →
operation → close channel` for every job**:

- `connect()` validates the printer (opens and closes a probe channel) and
  stores the logical connection, so the app can keep a `connected` state.
- `getPrinterStatus()`, `printImage()` and `printPdf()` open a fresh channel,
  run the operation and **always close the channel** afterwards — also when
  the operation fails or times out.

This is intentional: Brother printers (notably the QL series over
Bluetooth/BLE) accept **a single active connection**. Leaving a channel open
after the first command made them report "busy" and become unreachable until a
power cycle. Because every operation closes its channel, you can run status
queries and prints back-to-back without reconnecting; the only cost is a small
open/close round-trip per operation (a few seconds over BLE). On Android all
SDK calls run on a dedicated single thread, as required by the SDK.

## Known limitations

- On iOS the Bluetooth channel can only be obtained through discovery: call
  `discoverPrinters()` and pass a found printer to `connect()`.
- USB printing is supported on Android only.
- Discovery does not filter by model. Connection and printing are supported
  and tested only on the RJ-2050 and QL-820NWB models (other models return
  `invalidArgument` from `connect()`).

## FAQ

### Why can't I find my Bluetooth printer during discovery?

Brother Bluetooth printers must be **paired with the device first, through the
system Bluetooth settings**, before they can be located. The plugin does **not**
discover printers that aren't already paired with the phone/tablet, so there is
no "search for new Bluetooth devices" step inside the app.

To use a Bluetooth printer:

1. Turn the printer on.
2. Pair it from the OS Bluetooth settings (Android: *Settings → Bluetooth*;
   iOS: *Settings → Bluetooth*).
3. Run `discoverPrinters()` / `discoverPrintersStream()` — already-paired
   printers are reported as soon as the scan starts.

This applies to both classic Bluetooth and BLE, on Android and iOS.

### Are only the highlighted models supported?

Only the models **highlighted in the
[Supported printers](#supported-printers) table** — the RJ-2050 and the
QL-820NWB — are tested. However, the package is flexible:

- Discovery reports **all** compatible Brother printers returned by the SDK
  (no model filtering).
- The package ships **bundled custom paper definitions for many RJ/TD models**
  (`custom_paper/`), so paper sizes exist for more printers than the tested
  ones.
- Extending support to another printer is a small change: map its model in
  `connect()` (and provide its custom paper definition if needed). Pull
  requests for additional models are welcome.

### Why does `connect()` return `invalidArgument` for my model?

Connection and printing are implemented and tested only for the RJ-2050 and
QL-820NWB models. Passing any other model to `connect()` returns
`invalidArgument` on purpose — see the previous answer for how to extend
support to a new printer.

### Why do I need to request Bluetooth/location permissions on Android?

On Android 12+ the OS requires the `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`
runtime permissions before discovery can run. The example app uses
[`permission_handler`](https://pub.dev/packages/permission_handler) — make sure
your app requests these permissions **before** calling `discoverPrinters()`.

### Is USB supported on iOS?

No. USB printing is available on Android only. On iOS, printers can be reached
over Wi-Fi and Bluetooth/BLE.

### My printer is stuck as "busy" / unreachable. How do I recover it?

Brother printers (QL series over Bluetooth/BLE especially) accept a **single
active connection**. If the printer reports "busy" and ignores every command,
it is holding a stale session. The plugin never leaves a channel open after an
operation, but a printer stuck in this state by an old version, a crash, or an
app killed mid-print needs to be cleared:

1. `cancelPrinting()` — aborts an in-flight print (effective only if the SDK
   has not finished sending the job yet).
2. `disconnect()` — releases the logical connection.
3. If it still does not respond, **power-cycle the printer** (or toggle its
   Bluetooth); it clears the stale session on reboot.

## Example

Check the [`example/`](example/) folder for a complete demo app that performs
discovery, connection, image printing, PDF printing and custom paper setup.

## Documentation

- [API reference](https://pub.dev/documentation/brother_native_print/latest/)

## Contributing

Contributions are welcome! Please open an
[issue](https://github.com/FedeRotoli/brother_native_print/issues) or a
[pull request](https://github.com/FedeRotoli/brother_native_print/pulls).

## License

[MIT](LICENSE)


