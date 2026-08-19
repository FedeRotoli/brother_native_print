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
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import java.io.File

/**
 * Flutter plugin for Brother RJ-2050 and QL-820NWB printers.
 *
 * SDK class names verified against the BrotherPrintLibrary.aar
 * (Brother Print SDK for Android, package `com.brother.sdk.lmprinter`).
 */
class BrotherNativePrintPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var discoveryChannel: EventChannel
    private var context: Context? = null
    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    companion object {
        private const val TAG = "BrotherNativePrint"
    }

    /** Channels found in the last discovery, indexed to reopen the connection. */
    private val discoveredChannels = HashMap<String, Channel>()
    private var currentDriver: PrinterDriver? = null
    private var currentModel: PrinterModel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "brother_native_print/methods")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "brother_native_print/status")
        eventChannel.setStreamHandler(this)
        discoveryChannel = EventChannel(binding.binaryMessenger, "brother_native_print/discovery")
        discoveryChannel.setStreamHandler(discoveryStreamHandler)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
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
    // Discovery (streaming)
    // ------------------------------------------------------------------
    //
    // Discovery is exposed as a stream (`brother_native_print/discovery`
    // EventChannel): the already-paired classic Bluetooth printers are emitted
    // first (no waiting), then the Wi-Fi, BLE and USB searches run in parallel
    // and each printer is pushed to the stream as soon as it is found. The
    // stream is closed with `endOfStream()` when every requested search
    // finishes. This avoids the old behaviour where each blocking search ran
    // sequentially for the whole timeout (~sum of the timeouts).

    /** Event sink of the discovery channel. */
    private var discoveryEventSink: EventChannel.EventSink? = null
    private var discoveryJob: Job? = null

    /** Bumped on every start/cancel to drop emissions from stale searches. */
    private var discoveryGeneration = 0L

    private val discoveryStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            synchronized(this@BrotherNativePrintPlugin) {
                discoveryEventSink = events
                discoveredChannels.clear()
            }
            val args = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            val connectionTypes =
                (args["connectionTypes"] as? List<*>)?.map { it.toString() }?.toSet()
                    ?: setOf("wifi", "bluetooth")
            val timeoutMs = (args["timeoutMs"] as? Number)?.toInt() ?: 10_000
            startDiscoveryStreaming(connectionTypes, timeoutMs)
        }

        override fun onCancel(arguments: Any?) {
            cancelDiscovery()
            synchronized(this@BrotherNativePrintPlugin) { discoveryEventSink = null }
        }
    }

    private fun startDiscoveryStreaming(connectionTypes: Set<String>, timeoutMs: Int) {
        // Stop any in-flight discovery (also aborts the SDK scans).
        cancelDiscovery()

        val ctx = context ?: run {
            synchronized(this) { discoveryEventSink }?.error(
                "pluginNotInitialized", "Plugin not initialized", null
            )
            return
        }
        val generation = ++discoveryGeneration
        val durationSec = (timeoutMs / 1000.0).coerceAtLeast(1.0)

        discoveryJob = scope.launch {
            // Fast path: already-paired classic Bluetooth devices are emitted
            // immediately, without waiting for the Wi-Fi/BLE scans.
            if ("bluetooth" in connectionTypes) {
                val problem = ensureBluetoothPermissions()
                if (problem != null) {
                    Log.w(TAG, "Bluetooth discovery skipped: ${describeBluetoothProblem(problem)}")
                } else {
                    runCatching { PrinterSearcher.startBluetoothSearch(ctx).channels.toList() }
                        .onSuccess { list ->
                            Log.i(TAG, "Classic Bluetooth: ${list.size} paired device(s)")
                            list.forEach { emitChannel(it, generation) }
                        }
                        .onFailure { Log.w(TAG, "Classic Bluetooth search failed: ${it.message}") }
                }
            }

            // The Wi-Fi, BLE and USB searches run in parallel: the total time
            // is ~max(search durations), not the sum of the timeouts.
            val jobs = mutableListOf<Job>()
            if ("wifi" in connectionTypes) {
                jobs += launch {
                    runCatching { searchNetworkStreaming(ctx, durationSec, generation) }
                        .onFailure { Log.w(TAG, "Wi-Fi search failed: ${it.message}") }
                }
            }
            if ("bluetooth" in connectionTypes) {
                val problem = ensureBluetoothPermissions()
                if (problem != null) {
                    Log.w(TAG, "BLE discovery skipped: ${describeBluetoothProblem(problem)}")
                } else {
                    jobs += launch {
                        runCatching { searchBleStreaming(ctx, durationSec, generation) }
                            .onFailure { Log.w(TAG, "BLE search failed: ${it.message}") }
                    }
                }
            }
            if ("usb" in connectionTypes) {
                jobs += launch {
                    runCatching { PrinterSearcher.startUSBSearch(ctx).channels.toList() }
                        .onSuccess { list -> list.forEach { emitChannel(it, generation) } }
                        .onFailure { Log.w(TAG, "USB search failed: ${it.message}") }
                }
            }

            jobs.joinAll()
            endDiscovery(generation)
        }
    }

    /** Blocking Wi-Fi search that streams every channel as it is found. */
    private fun searchNetworkStreaming(ctx: Context, durationSec: Double, generation: Long) {
        val result = PrinterSearcher.startNetworkSearch(
            ctx,
            NetworkSearchOption(durationSec, false)
        ) { channel -> emitChannel(channel, generation) }
        val error = result.error
        if (error != null) {
            throw FlutterFailure("discoverFailed", "Wi-Fi search failed: ${error.code}")
        }
    }

    /** Blocking BLE search that streams every channel as it is found. */
    private fun searchBleStreaming(ctx: Context, durationSec: Double, generation: Long) {
        val result = PrinterSearcher.startBLESearch(
            ctx,
            BLESearchOption(durationSec)
        ) { channel -> emitChannel(channel, generation) }
        val error = result.error
        if (error != null) {
            throw FlutterFailure("discoverFailed", "BLE search failed: ${error.code}")
        }
    }

    /**
     * Deduplicates by channel key, caches the channel (so [connect] can reopen
     * it) and pushes the printer to the discovery stream.
     */
    private fun emitChannel(channel: Channel, generation: Long) {
        if (generation != discoveryGeneration) return
        val key = channelKey(channel)
        val shouldEmit = synchronized(this) {
            if (discoveredChannels.containsKey(key)) {
                false
            } else {
                discoveredChannels[key] = channel
                true
            }
        }
        if (!shouldEmit) return
        val sink = synchronized(this) { discoveryEventSink } ?: return
        sink.success(channelToMap(channel))
    }

    /** Closes the discovery stream when every requested search finished. */
    private fun endDiscovery(generation: Long) {
        if (generation != discoveryGeneration) return
        val sink = synchronized(this) { discoveryEventSink } ?: return
        sink.endOfStream()
    }

    /** Stops the current discovery and asks the SDK to abort the scans. */
    private fun cancelDiscovery() {
        discoveryGeneration++
        discoveryJob?.cancel()
        discoveryJob = null
        // Make the blocking SDK searches return early instead of waiting the
        // full timeout.
        runCatching { PrinterSearcher.cancelNetworkSearch() }
        runCatching { PrinterSearcher.cancelBLESearch() }
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
        "bluetoothDisabled" -> "Bluetooth is disabled: enable it before searching"
        "bluetoothUnsupported" -> "This device does not support Bluetooth"
        else -> "Bluetooth permissions are missing: grant them in the host app " +
            "(BLUETOOTH_SCAN/BLUETOOTH_CONNECT on Android 12+, ACCESS_FINE_LOCATION before)"
    }

    // ------------------------------------------------------------------
    // Connection
    // ------------------------------------------------------------------

    private fun connect(call: MethodCall): Boolean {
        val args = call.arguments as? Map<*, *>
            ?: throw FlutterFailure("invalidArgument", "Missing connection arguments")
        val modelName = args["model"] as? String
            ?: throw FlutterFailure("invalidArgument", "Missing 'model' field")
        val model = when {
            modelName.equals("RJ-2050", ignoreCase = true) -> PrinterModel.RJ_2050
            modelName.equals("QL-820NWB", ignoreCase = true) -> PrinterModel.QL_820NWB
            else -> throw FlutterFailure("invalidArgument", "Unsupported model: $modelName")
        }
        val connectionType = args["connectionType"] as? String
            ?: throw FlutterFailure("invalidArgument", "Missing 'connectionType' field")
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
                    openError.errorRecoverySuggestion ?: "Unable to open the channel"
                )
            }
            val driver = openResult.driver
                ?: throw FlutterFailure("communicationLost", "Driver not available")
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

        val ctx = context ?: throw IllegalStateException("Plugin not initialized")
        return when (connectionType) {
            "wifi" -> {
                val address = ip
                    ?: throw FlutterFailure("invalidArgument", "Missing IP address")
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
                        "Missing MAC address: for Bluetooth, call discoverPrinters first " +
                            "and connect to a found printer"
                    )
                // The SDK BLE channel is built from the information advertised by
                // the device; if it is not available from discovery, fall back to
                // the MAC address received from Dart.
                Channel.newBluetoothLowEnergyChannel(address, ctx, adapter)
            }
            "usb" -> throw FlutterFailure(
                "printerUnreachable",
                "USB connection is only possible through a printer found in discoverPrinters"
            )
            else -> throw FlutterFailure("invalidArgument", "Unsupported connection type")
        }
    }

    // ------------------------------------------------------------------
    // Printing
    // ------------------------------------------------------------------

    private fun printImage(call: MethodCall): Map<String, Any?> {
        val driver = requireDriver()
        val imageBytes = call.argument<ByteArray>("imageBytes")
            ?: throw FlutterFailure("invalidArgument", "Missing image bytes")
        val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()

        val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: throw FlutterFailure("invalidArgument", "Invalid image format")
        try {
            val error = driver.printImage(bitmap, createSettings(options))
            return printResultMap(error)
        } finally {
            bitmap.recycle()
        }
    }

    private fun printPdf(call: MethodCall): Map<String, Any?> {
        val driver = requireDriver()
        val ctx = context ?: throw IllegalStateException("Plugin not initialized")
        val pdfBytes = call.argument<ByteArray>("pdfBytes")
            ?: throw FlutterFailure("invalidArgument", "Missing PDF bytes")
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
            "No printer connected: call connect() before printing"
        )

    private fun createSettings(options: Map<String, Any?>): PrintSettings {
        val model = currentModel
            ?: throw FlutterFailure("printerUnreachable", "Model not set")
        val copies = (options["copies"] as? Number)?.toInt()?.coerceIn(1, 99) ?: 1
        val autoCut = options["autoCut"] as? Boolean ?: true
        val paperType = options["paperType"] as? String
        return when (model) {
            PrinterModel.RJ_2050 -> RJPrintSettings(model).apply {
                numCopies = copies
                scaleMode = PrintImageSettings.ScaleMode.FitPageAspect
                // Over Bluetooth the pre-print status request can fail
                // ("Failed to get status") on some RJ models: skip it.
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
            else -> throw FlutterFailure("invalidArgument", "Unsupported model: $model")
        }
    }

    /**
     * Applies the custom paper size for the RJ series.
     *
     * For the RJ/TD series the official Brother documentation requires the
     * paper to be specified: for the RJ-2050 (2") a 2.0 inch roll with zero
     * margins is used (see the "Printing Image/PDF" guide, RJ/TD section).
     */
    private fun applyCustomPaper(settings: RJPrintSettings, options: Map<String, Any?>) {
        // If the app provided a .bin file (Brother Paper Size Setup Tool), use
        // it: it is the most reliable paper definition for the connected printer.
        val binPath = options["paperBinPath"] as? String
        if (!binPath.isNullOrEmpty()) {
            settings.customPaperSize = CustomPaperSize.newFile(binPath)
            return
        }
        // Aligned with iOS: margins top=3, left=2, bottom=3, right=2 (mm) and a
        // default 58 mm roll. With 2 mm on each side the printable area becomes
        // 54 mm (RJ-2050 printhead: 432 dots at 203 dpi).
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
    // Channels -> Dart map
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
            // Model name as reported by the SDK (e.g. "RJ-2050", "QL-820NWB").
            "model" to modelName,
            "connectionType" to connectionType,
            "ipAddress" to (info?.get(Channel.ExtraInfoKey.IpAddress)
                ?: if (channel.channelType == Channel.ChannelType.Wifi) channel.channelInfo else null),
            "macAddress" to info?.get(Channel.ExtraInfoKey.MACAddress),
            // NB: the SDK key is "SerialNubmer" (official Brother typo).
            "serialNumber" to (info?.get(Channel.ExtraInfoKey.SerialNubmer) ?: ""),
        )
    }

    // ------------------------------------------------------------------
    // Status
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
        cancelDiscovery()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        discoveryChannel.setStreamHandler(null)
        scope.cancel()
    }

    private class FlutterFailure(val code: String, message: String) : Exception(message)
}

