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
