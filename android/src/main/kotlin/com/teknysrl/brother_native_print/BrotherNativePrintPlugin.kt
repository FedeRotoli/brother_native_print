package com.teknysrl.brother_native_print

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import com.brother.sdk.lmprinter.BLESearchOption
import com.brother.sdk.lmprinter.Channel
import com.brother.sdk.lmprinter.NetworkSearchOption
import com.brother.sdk.lmprinter.OpenChannelError
import com.brother.sdk.lmprinter.PrintError
import com.brother.sdk.lmprinter.PrinterDriver
import com.brother.sdk.lmprinter.PrinterDriverGenerator
import com.brother.sdk.lmprinter.PrinterModel
import com.brother.sdk.lmprinter.PrinterSearcher
import com.brother.sdk.lmprinter.setting.CustomPaperSize
import com.brother.sdk.lmprinter.setting.PrintImageSettings
import com.brother.sdk.lmprinter.setting.PrintSettings
import com.brother.sdk.lmprinter.setting.QLPrintSettings
import com.brother.sdk.lmprinter.setting.RJPrintSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File

/**
 * Plugin Flutter per stampanti Brother RJ-2050 e QL-820NWB.
 *
 * Nomi delle classi SDK verificati sull'AAR BrotherPrintLibrary.aar
 * (Brother Print SDK for Android, package `com.brother.sdk.lmprinter`).
 */
class BrotherNativePrintPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null
    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    companion object {
        private const val TAG = "BrotherNativePrint"
    }

    /** Canali trovati nell'ultima discovery, indicizzati per riaprire la connessione. */
    private val discoveredChannels = HashMap<String, Channel>()
    private var currentDriver: PrinterDriver? = null
    private var currentModel: PrinterModel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "brother_native_print/methods")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "brother_native_print/status")
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "discoverPrinters" -> scope.launch {
                try {
                    result.success(discoverPrinters(call))
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            "connect" -> scope.launch {
                try {
                    result.success(connect(call))
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            "disconnect" -> scope.launch {
                try {
                    synchronized(this@BrotherNativePrintPlugin) {
                        runCatching { currentDriver?.closeChannel() }
                        currentDriver = null
                        currentModel = null
                    }
                    emitState("disconnected")
                    result.success(null)
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            "printImage" -> scope.launch {
                try {
                    result.success(printImage(call))
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            "printPdf" -> scope.launch {
                try {
                    result.success(printPdf(call))
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------
    // Discovery
    // ------------------------------------------------------------------

    private fun discoverPrinters(call: MethodCall): List<Map<String, Any?>> {
        val ctx = context ?: throw IllegalStateException("Plugin non inizializzato")
        val connectionTypes =
            call.argument<List<String>>("connectionTypes")?.toSet() ?: setOf("wifi", "bluetooth")
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 10_000
        val durationSec = (timeoutMs / 1000.0).coerceAtLeast(1.0)

        val channels = LinkedHashMap<String, Channel>()
        if ("wifi" in connectionTypes) {
            runCatching { searchNetwork(ctx, durationSec) }
                .onFailure { Log.w(TAG, "Ricerca Wi-Fi fallita: ${it.message}") }
                .getOrDefault(emptyList())
                .forEach { channels[channelKey(it)] = it }
        }
        if ("bluetooth" in connectionTypes) {
            val problem = ensureBluetoothPermissions()
            if (problem != null) {
                // Non blocca la discovery: registra il problema e continua con
                // gli altri canali richiesti (es. Wi-Fi).
                Log.w(TAG, "Discovery Bluetooth saltata: ${describeBluetoothProblem(problem)}")
            } else {
                runCatching { searchBle(ctx, durationSec) }
                    .onFailure { Log.w(TAG, "Ricerca BLE fallita: ${it.message}") }
                    .getOrDefault(emptyList())
                    .forEach { channels[channelKey(it)] = it }
                // Bluetooth classico (SPP): tentativo aggiuntivo per i modelli
                // che lo supportano (RJ-2050, QL-820NWB usano SPP classico).
                runCatching { PrinterSearcher.startBluetoothSearch(ctx).channels.toList() }
                    .onFailure { Log.w(TAG, "Ricerca Bluetooth classico fallita: ${it.message}") }
                    .getOrDefault(emptyList())
                    .forEach { channels[channelKey(it)] = it }
            }
        }
        if ("usb" in connectionTypes) {
            runCatching { PrinterSearcher.startUSBSearch(ctx).channels.toList() }
                .onFailure { Log.w(TAG, "Ricerca USB fallita: ${it.message}") }
                .getOrDefault(emptyList())
                .forEach { channels[channelKey(it)] = it }
        }

        synchronized(this) {
            discoveredChannels.clear()
            channels.forEach { (key, channel) -> discoveredChannels[key] = channel }
        }

        // Nessun filtro sul modello: vengono restituite tutte le stampanti
        // Brother compatibili trovate dall'SDK.
        return channels.values.map { channelToMap(it) }
    }

    private fun searchNetwork(ctx: Context, durationSec: Double): List<Channel> {
        val result = PrinterSearcher.startNetworkSearch(
            ctx,
            NetworkSearchOption(durationSec, false)
        ) { /* i canali vengono raccolti dal risultato sincrono */ }
        val error = result.error
        if (error != null) {
            throw FlutterFailure("discoverFailed", "Ricerca Wi-Fi fallita: ${error.code}")
        }
        return result.channels.toList()
    }

    private fun searchBle(ctx: Context, durationSec: Double): List<Channel> {
        val result = PrinterSearcher.startBLESearch(
            ctx,
            BLESearchOption(durationSec)
        ) { /* i canali vengono raccolti dal risultato sincrono */ }
        val error = result.error
        if (error != null) {
            throw FlutterFailure("discoverFailed", "Ricerca BLE fallita: ${error.code}")
        }
        return result.channels.toList()
    }

    private fun ensureBluetoothPermissions(): String? {
        val ctx = context ?: return "permissionMissing"
        val adapter = BluetoothAdapter.getDefaultAdapter()
            ?: return "bluetoothUnsupported"
        if (!adapter.isEnabled) return "bluetoothDisabled"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val scanGranted = ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED
            val connectGranted = ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
            if (!scanGranted || !connectGranted) "permissionMissing" else null
        } else {
            val locationGranted = ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
            if (!locationGranted) "permissionMissing" else null
        }
    }

    private fun describeBluetoothProblem(problem: String): String = when (problem) {
        "bluetoothDisabled" -> "Bluetooth disattivato: attivarlo prima della ricerca"
        "bluetoothUnsupported" -> "Dispositivo senza supporto Bluetooth"
        else -> "Permessi Bluetooth mancanti: concederli nell'app host " +
            "(BLUETOOTH_SCAN/BLUETOOTH_CONNECT su Android 12+, ACCESS_FINE_LOCATION prima)"
    }

    // ------------------------------------------------------------------
    // Connessione
    // ------------------------------------------------------------------

    private fun connect(call: MethodCall): Boolean {
        val args = call.arguments as? Map<*, *>
            ?: throw FlutterFailure("invalidArgument", "Argomenti connessione mancanti")
        val modelName = args["model"] as? String
            ?: throw FlutterFailure("invalidArgument", "Campo 'model' mancante")
        val model = when {
            modelName.equals("RJ-2050", ignoreCase = true) -> PrinterModel.RJ_2050
            modelName.equals("QL-820NWB", ignoreCase = true) -> PrinterModel.QL_820NWB
            else -> throw FlutterFailure("invalidArgument", "Modello non supportato: $modelName")
        }
        val connectionType = args["connectionType"] as? String
            ?: throw FlutterFailure("invalidArgument", "Campo 'connectionType' mancante")
        val ip = args["ipAddress"] as? String
        val mac = args["macAddress"] as? String
        val serial = args["serialNumber"] as? String

        val channel = resolveChannel(connectionType, ip, mac, serial)

        synchronized(this) {
            val openResult = PrinterDriverGenerator.openChannel(channel)
            val openError = openResult.error
            if (openError != null) {
                throw FlutterFailure(
                    mapOpenChannelError(openError.code),
                    openError.errorRecoverySuggestion ?: "Impossibile aprire il canale"
                )
            }
            val driver = openResult.driver
                ?: throw FlutterFailure("communicationLost", "Driver non disponibile")
            runCatching { currentDriver?.closeChannel() }
            currentDriver = driver
            currentModel = model
        }
        emitState("connected")
        return true
    }

    private fun resolveChannel(
        connectionType: String,
        ip: String?,
        mac: String?,
        serial: String?,
    ): Channel {
        val key = when (connectionType) {
            "wifi" -> "wifi|${ip ?: ""}"
            "bluetooth" -> "bluetooth|${mac ?: ""}"
            else -> "usb|${serial ?: ""}"
        }
        synchronized(this) { discoveredChannels[key] }?.let { return it }

        val ctx = context ?: throw IllegalStateException("Plugin non inizializzato")
        return when (connectionType) {
            "wifi" -> {
                val address = ip
                    ?: throw FlutterFailure("invalidArgument", "Indirizzo IP mancante")
                Channel.newWifiChannel(address)
            }
            "bluetooth" -> {
                ensureBluetoothPermissions()?.let { problem ->
                    throw FlutterFailure(problem, describeBluetoothProblem(problem))
                }
                val adapter = BluetoothAdapter.getDefaultAdapter()
                val address = mac
                    ?: throw FlutterFailure(
                        "invalidArgument",
                        "Indirizzo MAC mancante: per il Bluetooth eseguire prima " +
                            "discoverPrinters e connettersi al risultato trovato"
                    )
                // Il canale BLE dell'SDK si costruisce a partire dall'informazione
                // pubblicizzata dal dispositivo; se non è disponibile dalla discovery,
                // si tenta con l'indirizzo MAC ricevuto da Dart.
                Channel.newBluetoothLowEnergyChannel(address, ctx, adapter)
            }
            "usb" -> throw FlutterFailure(
                "printerUnreachable",
                "Connessione USB possibile solo tramite stampante trovata in discoverPrinters"
            )
            else -> throw FlutterFailure("invalidArgument", "Tipo di connessione non supportato")
        }
    }

    // ------------------------------------------------------------------
    // Stampa
    // ------------------------------------------------------------------

    private fun printImage(call: MethodCall): Map<String, Any?> {
        val driver = requireDriver()
        val imageBytes = call.argument<ByteArray>("imageBytes")
            ?: throw FlutterFailure("invalidArgument", "Bytes immagine mancanti")
        val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()

        val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: throw FlutterFailure("invalidArgument", "Formato immagine non valido")
        try {
            val error = driver.printImage(bitmap, createSettings(options))
            return printResultMap(error)
        } finally {
            bitmap.recycle()
        }
    }

    private fun printPdf(call: MethodCall): Map<String, Any?> {
        val driver = requireDriver()
        val ctx = context ?: throw IllegalStateException("Plugin non inizializzato")
        val pdfBytes = call.argument<ByteArray>("pdfBytes")
            ?: throw FlutterFailure("invalidArgument", "Bytes PDF mancanti")
        val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()

        val file = File(ctx.cacheDir, "brother_print_${System.currentTimeMillis()}.pdf")
        return try {
            file.writeBytes(pdfBytes)
            printResultMap(driver.printPDF(file.absolutePath, createSettings(options)))
        } finally {
            runCatching { file.delete() }
        }
    }

    private fun requireDriver(): PrinterDriver =
        currentDriver ?: throw FlutterFailure(
            "printerUnreachable",
            "Nessuna stampante connessa: chiamare connect() prima di stampare"
        )

    private fun createSettings(options: Map<String, Any?>): PrintSettings {
        val model = currentModel
            ?: throw FlutterFailure("printerUnreachable", "Modello non impostato")
        val copies = (options["copies"] as? Number)?.toInt()?.coerceIn(1, 99) ?: 1
        val autoCut = options["autoCut"] as? Boolean ?: true
        val paperType = options["paperType"] as? String
        return when (model) {
            PrinterModel.RJ_2050 -> RJPrintSettings(model).apply {
                numCopies = copies
                scaleMode = PrintImageSettings.ScaleMode.FitPageAspect
                // Via Bluetooth la richiesta di stato pre-stampa può fallire
                // ("Failed to get status") su alcuni modelli RJ: la saltiamo.
                isSkipStatusCheck = true
                applyCustomPaper(this, options)
            }
            PrinterModel.QL_820NWB -> QLPrintSettings(model).apply {
                numCopies = copies
                isAutoCut = autoCut
                scaleMode = PrintImageSettings.ScaleMode.FitPageAspect
                isSkipStatusCheck = true
                paperType?.let {
                    runCatching { labelSize = QLPrintSettings.LabelSize.valueOf(it) }
                }
            }
            else -> throw FlutterFailure("invalidArgument", "Modello non supportato: $model")
        }
    }

    /**
     * Imposta la custom paper size per la serie RJ.
     *
     * Per la serie RJ/TD la documentazione ufficiale Brother richiede di
     * specificare la carta: per la RJ-2050 (2") si usa un rotolo da 2.0 inch
     * con margini zero (vedi guida "Printing Image/PDF", sezione RJ/TD).
     */
    private fun applyCustomPaper(settings: RJPrintSettings, options: Map<String, Any?>) {
        // Se l'app ha fornito un file .bin (Brother Paper Size Setup Tool) usa
        // quello: è la definizione carta più affidabile per la stampante connessa.
        val binPath = options["paperBinPath"] as? String
        if (!binPath.isNullOrEmpty()) {
            settings.customPaperSize = CustomPaperSize.newFile(binPath)
            return
        }
        // Allineato a iOS: margini top=3, left=2, bottom=3, right=2 (mm) e
        // rotolo di default da 58 mm. Con 2 mm per lato l'area stampabile
        // diventa 54 mm (testina RJ-2050: 432 dot a 203 dpi).
        val margins = CustomPaperSize.Margins(3f, 2f, 3f, 2f)
        val widthMm = (options["paperWidthMm"] as? Number)?.toFloat() ?: 58f
        settings.customPaperSize = CustomPaperSize.newRollPaperSize(
            widthMm,
            margins,
            CustomPaperSize.Unit.Mm
        )
    }

    private fun printResultMap(error: PrintError?): Map<String, Any?> {
        if (error == null || error.code == PrintError.ErrorCode.NoError) {
            return mapOf("success" to true)
        }
        val code = when (error.code) {
            PrintError.ErrorCode.PrinterStatusErrorPaperEmpty -> "outOfPaper"
            PrintError.ErrorCode.PrinterStatusErrorCoverOpen -> "coverOpen"
            PrintError.ErrorCode.ChannelTimeout -> "timeout"
            PrintError.ErrorCode.PrinterStatusErrorCommunicationError,
            PrintError.ErrorCode.ChannelErrorStreamStatusError,
            PrintError.ErrorCode.PrinterStatusErrorPrinterTurnedOff -> "communicationLost"
            else -> "unknown"
        }
        return mapOf(
            "success" to false,
            "error" to mapOf(
                "code" to code,
                "message" to (error.errorDescription ?: error.code.name),
            ),
        )
    }

    private fun mapOpenChannelError(code: OpenChannelError.ErrorCode): String = when (code) {
        OpenChannelError.ErrorCode.Timeout -> "timeout"
        OpenChannelError.ErrorCode.InsufficientPermissions -> "permissionMissing"
        else -> "communicationLost"
    }

    // ------------------------------------------------------------------
    // Canali -> mappa Dart
    // ------------------------------------------------------------------

    private fun channelKey(channel: Channel): String {
        val info = channel.extraInfo
        val ip = info?.get(Channel.ExtraInfoKey.IpAddress) ?: ""
        val mac = info?.get(Channel.ExtraInfoKey.MACAddress) ?: ""
        val serial = info?.get(Channel.ExtraInfoKey.SerialNubmer) ?: ""
        return when (channel.channelType) {
            Channel.ChannelType.Wifi -> "wifi|$ip"
            Channel.ChannelType.Bluetooth,
            Channel.ChannelType.BluetoothLowEnergy -> "bluetooth|$mac"
            else -> "usb|$serial"
        }
    }

    private fun channelToMap(channel: Channel): Map<String, Any?> {
        val info = channel.extraInfo
        val modelName = (info?.get(Channel.ExtraInfoKey.ModelName) as? String)
            ?.takeIf { it.isNotBlank() } ?: "Unknown"
        val connectionType = when (channel.channelType) {
            Channel.ChannelType.Wifi -> "wifi"
            Channel.ChannelType.Bluetooth,
            Channel.ChannelType.BluetoothLowEnergy -> "bluetooth"
            else -> "usb"
        }
        return mapOf(
            // Nome del modello riportato dall'SDK (es. "RJ-2050", "QL-820NWB").
            "model" to modelName,
            "connectionType" to connectionType,
            "ipAddress" to (info?.get(Channel.ExtraInfoKey.IpAddress)
                ?: if (channel.channelType == Channel.ChannelType.Wifi) channel.channelInfo else null),
            "macAddress" to info?.get(Channel.ExtraInfoKey.MACAddress),
            // NB: nell'SDK la chiave è "SerialNubmer" (typo ufficiale di Brother).
            "serialNumber" to (info?.get(Channel.ExtraInfoKey.SerialNubmer) ?: ""),
        )
    }

    // ------------------------------------------------------------------
    // Stato
    // ------------------------------------------------------------------

    private fun emitState(state: String, error: Map<String, Any?>? = null) {
        eventSink?.success(mapOf("state" to state, "error" to error))
    }

    private fun failureCode(e: Exception): String = when (e) {
        is FlutterFailure -> e.code
        else -> "unknown"
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emitState(if (currentDriver != null) "connected" else "disconnected")
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(this) {
            runCatching { currentDriver?.closeChannel() }
            currentDriver = null
            discoveredChannels.clear()
        }
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        scope.cancel()
    }

    private class FlutterFailure(val code: String, message: String) : Exception(message)
}

