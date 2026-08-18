# brother_native_print

Plugin Flutter per la stampa con stampanti Brother via WiFi, Bluetooth (BLE) e
USB (solo Android). La discovery mostra **tutte le stampanti Brother
compatibili** trovate, senza filtri sul modello; la stampa di immagini e PDF è
supportata e testata su **RJ-2050** e **QL-820NWB**.

Basato su:
- **Android**: Brother Print SDK for Android (`com.brother.sdk.lmprinter`),
  distribuito come AAR locale tramite repository Maven in `android/maven-repo`.
- **iOS**: BRLMPrinterKit (variante BT_Net) distribuito come **xcframework binario**
  via **Swift Package Manager** (nessun CocoaPods).

## API

```dart
final plugin = BrotherNativePrint();

// Discovery (WiFi + Bluetooth di default)
final printers = await plugin.discoverPrinters();

// Connessione
await plugin.connect(printer);

// Stato (stream)
plugin.statusStream.listen((status) => print(status.state));

// Stampa
final result = await plugin.printImage(imageBytes); // PNG/JPEG
final result = await plugin.printPdf(pdfBytes);

// Disconnessione
await plugin.disconnect();
```

`PrintOptions` consente `copies`, `paperType` (per QL-820NWB, es. `RollW62`) e
`autoCut`. Gli errori sono normalizzati in `BrotherPrintErrorCode`.

## Setup app host — Android

1. L'AAR Brother è pubblicato nel repository Maven locale del plugin
   (`android/maven-repo`). AGP 9 non supporta dipendenze `.aar` locali dirette
   quando si compila un AAR, quindi nell'app host va registrato il repository:

   ```kotlin
   // android/build.gradle.kts dell'app host
   allprojects {
       repositories {
           google()
           mavenCentral()
           maven { url = uri("$rootDir/<path-del-plugin>/android/maven-repo") }
       }
   }
   ```

2. Permessi in `AndroidManifest.xml` dell'app host (richiesti dall'app, il
   plugin fallisce con un errore chiaro se mancano):

   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
   <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
   <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
   <uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
   <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
   ```

   Su Android 12+ vanno anche richiesti a runtime (`BLUETOOTH_SCAN`,
   `BLUETOOTH_CONNECT`), prima di `discoverPrinters`.

## Setup app host — iOS (solo SPM)

1. Abilitare SPM nel tooling: `flutter config --enable-swift-package-manager`.
2. In `ios/Runner/Info.plist` aggiungere:

   ```xml
   <key>NSBluetoothAlwaysUsageDescription</key>
   <string>Serve per cercare e collegarsi alle stampanti Brother via Bluetooth</string>
   <key>NSBluetoothPeripheralUsageDescription</key>
   <string>Serve per cercare e collegarsi alle stampanti Brother via Bluetooth</string>
   <key>NSLocalNetworkUsageDescription</key>
   <string>Serve per cercare le stampanti Brother sulla rete locale</string>
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

   In Xcode, il plugin appare come **Package Dependencies** con
   `brother_native_print` e `BRLMPrinterKit`.

## Limiti noti

- Su iOS il canale Bluetooth si ottiene dalla discovery: chiamare
  `discoverPrinters` e passare a `connect` una stampante trovata.
- USB supportato solo su Android.
- La discovery non applica filtri: mostra tutte le stampanti Brother
  compatibili trovate. La connessione/stampa è supportata e testata solo sui
  modelli RJ-2050 e QL-820NWB (per gli altri modelli `connect` restituisce
  `invalidArgument`).


