# brother_native_print example

A complete demo app for the [`brother_native_print`](https://pub.dev/packages/brother_native_print) plugin.

## What it does

The app lets you:

- Request the required Bluetooth/location permissions at runtime.
- Discover Brother printers over Wi-Fi and Bluetooth.
- Connect to and disconnect from a printer, watching its connection state.
- Print a generated test **image** (PNG) to the connected printer.
- Print a generated in-memory **PDF** to the connected printer.
- Load a **custom paper** definition (`.bin`, bundled with the plugin and
  extracted via `BrotherCustomPaper`) and apply it when printing to an RJ
  printer.

## Platform setup

Before running, follow the Android/iOS setup steps described in the
[plugin README](../README.md#platform-setup).

## Running

```sh
flutter run
```

On Android 12+ the app asks for the Bluetooth/location permissions when you
press the search icon; on iOS, grant Bluetooth and Local Network access when
prompted.

## Code layout

The app is split into small, focused folders under `lib/src/`:

| Path | Purpose |
| --- | --- |
| `screens/home_screen.dart` | The UI (renders the controller state, forwards actions). |
| `services/printer_controller.dart` | All the plugin logic (discovery, connect, print, status) as a `ChangeNotifier`. |
| `labels/traceability_label.dart` | Generates the demo PNG label to print. |
| `labels/test_pdf.dart` | Generates the demo PDF to print. |

The UI never talks to the plugin directly: it reads state from
`PrinterController` and calls its methods, keeping the widgets free of
platform logic so the app is easy to read and extend.

## Notes

- The test image is a 732x420 px bitmap sized for the QL-820NWB **62 mm roll**
  (`RollW62`, the SDK default). The QL label size is matched to the cassette
  the printer actually detected (via `getPrinterStatus()`), cached per
  connection; the RJ-2050 uses the bundled custom paper.
- The test PDF uses the embedded Roboto font so that accented/Unicode
  characters render correctly.
- The `.bin` custom paper files are bundled with the plugin package (see the
  plugin README for details) and are loaded at runtime via
  `BrotherCustomPaper`, so the example ships no duplicate copies.
