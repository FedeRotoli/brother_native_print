package com.teknysrl.brother_native_print

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import com.brother.sdk.lmprinter.BLESearchOption
import com.brother.sdk.lmprinter.Channel
import com.brother.sdk.lmprinter.GetStatusError
import com.brother.sdk.lmprinter.GetStatusResult
import com.brother.sdk.lmprinter.NetworkSearchOption
import com.brother.sdk.lmprinter.OpenChannelError
import com.brother.sdk.lmprinter.PrintError
import com.brother.sdk.lmprinter.PrinterDriver
import com.brother.sdk.lmprinter.PrinterStatus
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
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

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

    /**
     * Dedicated single-thread executor for every SDK driver operation.
     *
     * The Brother SDK requires the driver to be used from a single thread
     * ("Methods MUST be called on a single thread"), and a status query that
     * outlives its Dart-side timeout must not overlap the next print. All
     * connect/status/print calls run here, in order; disconnect and
     * cancelPrinting stay off this thread so they can abort a stuck call.
     */
    private val printExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "brother-print").apply { isDaemon = true }
    }
    private val printDispatcher = printExecutor.asCoroutineDispatcher()

    companion object {
        private const val TAG = "BrotherNativePrint"
    }

    /** Channels found in the last discovery, indexed to reopen the connection. */
    private val discoveredChannels = HashMap<String, Channel>()

    /**
     * Logical connection to the printer. The physical channel is opened per
     * operation (Brother pattern: open -> operation -> close), so the printer
     * is never left with a stale session that reports "busy" on the next
     * command.
     */
    private var connectedPrinter: ConnectedPrinter? = null

    /**
     * Driver of the operation currently in flight on [printDispatcher], so
     * [cancelPrinting] can reach it from another thread while a print is stuck.
     */
    @Volatile
    private var currentDriver: PrinterDriver? = null
    private var currentModel: PrinterModel? = null

    private data class ConnectedPrinter(
        val model: PrinterModel,
        /** Original model name string passed by Dart (e.g. "RJ-2050"). */
        val modelName: String,
        val connectionType: String,
        val ip: String?,
        val mac: String?,
        val serial: String?,
    )

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
        // connect / printImage / printPdf / getStatus run on the single print
        // thread, so the SDK driver is never touched from two threads at once
        // (the SDK requires it and a race can hang the channel).
        when (call.method) {
            "connect" -> scope.launch(printDispatcher) {
                try {
                    result.success(connect(call))
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            // disconnect and cancelPrinting do not run the SDK driver: they
            // must be serviced even while the print thread is blocked by a
            // stuck call, so they use their own scope.
            "disconnect" -> scope.launch {
                try {
                    disconnect()
                    result.success(null)
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            // Reads the stored logical connection: non-blocking, no SDK
            // driver involved, so it is served on the calling thread.
            "getConnectedPrinter" -> result.success(getConnectedPrinter())
            "cancelPrinting" -> scope.launch {
                try {
                    cancelPrinting()
                    result.success(null)
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            "printImage" -> scope.launch(printDispatcher) {
                try {
                    result.success(printImage(call))
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            "printPdf" -> scope.launch(printDispatcher) {
                try {
                    result.success(printPdf(call))
                } catch (e: Exception) {
                    result.error(failureCode(e), e.message, null)
                }
            }
            "getStatus" -> scope.launch(printDispatcher) {
                try {
                    result.success(getStatus())
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
                // Unicast subnet sweep fallback: the SDK network search uses a
                // broadcast that some routers/printer firmware ignore, so even
                // with the phone and the printer on the same healthy network it
                // can report 0 printers. Probing every host on the phone's
                // subnet directly (unicast SNMP, same OID the SDK uses) finds
                // those printers too. Runs in parallel with the SDK search.
                jobs += launch {
                    runCatching { searchNetworkUnicastSweep(ctx, timeoutMs, generation) }
                        .onFailure { Log.w(TAG, "Unicast sweep failed: ${it.message}") }
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

    /**
     * Fallback Wi-Fi discovery: probes every host on the phone's subnet with a
     * unicast SNMP GET asking for the Brother model OID.
     *
     * The SDK network search relies on a broadcast that some routers filter and
     * that some printer firmware ignores (responding only to unicast SNMP), so
     * it can return 0 printers even on a healthy network. This sweep talks to
     * each host directly, so it finds those printers too.
     */
    private fun searchNetworkUnicastSweep(ctx: Context, timeoutMs: Int, generation: Long) {
        val info = wifiSubnetInfo()
        if (info == null) {
            Log.w(TAG, "Unicast sweep skipped: phone is not on a Wi-Fi network")
            return
        }
        val (ownIp, prefix) = info
        val hosts = buildHostList(ownIp, prefix)
            ?: run {
                Log.w(TAG, "Unicast sweep skipped: cannot compute the subnet for $ownIp/$prefix")
                return
            }
        if (hosts.isEmpty()) {
            Log.w(TAG, "Unicast sweep skipped: empty subnet for $ownIp/$prefix")
            return
        }
        Log.i(TAG, "Unicast sweep: scanning ${hosts.size} hosts on $ownIp/$prefix")

        val found = AtomicInteger(0)
        val latch = CountDownLatch(hosts.size)
        val executor = Executors.newFixedThreadPool(32) { r ->
            Thread(r, "brother-sweep").apply { isDaemon = true }
        }
        try {
            for (host in hosts) {
                executor.execute {
                    try {
                        if (generation != discoveryGeneration) return@execute
                        // The SDK reads the model from hrDeviceDescr (Host
                        // Resources), so probe it first; hosts that respond
                        // without a model value fall back to sysDescr and the
                        // Brother private MIB.
                        val first = SnmpProbe.probe(host, SnmpProbe.HR_DEVICE_DESCR_OID, 500)
                        if (generation != discoveryGeneration) return@execute
                        if (!first.responded) return@execute
                        var clean = normalizeModel(first.value)
                        if (clean == null) {
                            val desc = SnmpProbe.probe(host, SnmpProbe.SYSDESCR_OID, 300)
                            clean = normalizeModel(desc.value)
                        }
                        if (clean == null) {
                            val privateModel = SnmpProbe.probe(host, SnmpProbe.MODEL_OID, 300)
                            clean = normalizeModel(privateModel.value)
                        }
                        if (clean == null) return@execute
                        val channel = Channel.newWifiChannel(host).apply {
                            extraInfo[Channel.ExtraInfoKey.ModelName] = clean
                            extraInfo[Channel.ExtraInfoKey.IpAddress] = host
                        }
                        emitChannel(channel, generation)
                        found.incrementAndGet()
                        Log.i(TAG, "Unicast sweep found $clean at $host")
                    } finally {
                        latch.countDown()
                    }
                }
            }
            // Hard cap so a slow/unusual network cannot stall the discovery.
            latch.await(20, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
        }
        Log.i(TAG, "Unicast sweep finished: ${found.get()} printer(s) found")
    }

    /**
     * Normalizes an SNMP model string and returns null when the device is not
     * a Brother printer.
     *
     * connect() only accepts "QL-820NWB"/"RJ-2050", so those exact tokens are
     * extracted (from "Brother QL-820NWB", "QL_820NWB", "QL-820NWB Label
     * Printer"...). Any other model is kept only when the device self-identifies
     * as Brother ("Brother ..." in the description): non-Brother printers that
     * answer SNMP (e.g. HP, Epson) are filtered out.
     */
    private fun normalizeModel(raw: String?): String? {
        val trimmed = raw?.trim()?.removePrefix("Brother ")?.trim()
        if (trimmed.isNullOrEmpty()) return null
        val upper = trimmed.uppercase().replace('_', '-')
        if (upper.contains("QL-820NWB")) return "QL-820NWB"
        if (upper.contains("RJ-2050")) return "RJ-2050"
        return if (upper.contains("BROTHER")) trimmed else null
    }

    /** The phone's Wi-Fi address and prefix length, or null when not on Wi-Fi. */
    private fun wifiSubnetInfo(): Pair<String, Int>? {
        val ctx = context ?: return null
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return null
        val network = cm.activeNetwork ?: return null
        val capabilities = cm.getNetworkCapabilities(network) ?: return null
        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null
        val linkProperties = cm.getLinkProperties(network) ?: return null
        for (address in linkProperties.linkAddresses) {
            val inet = address.address ?: continue
            if (inet is Inet4Address) {
                return Pair(inet.hostAddress ?: continue, address.prefixLength)
            }
        }
        return null
    }

    /**
     * Lists the host addresses on the phone's subnet to probe.
     *
     * The scan is bounded to a /24 around the phone (254 hosts) even when the
     * real prefix is larger, to keep the sweep fast on big/office networks.
     */
    private fun buildHostList(ownIp: String, prefix: Int): List<String>? {
        val bytes = runCatching { InetAddress.getByName(ownIp).address }.getOrNull() ?: return null
        if (bytes.size != 4) return null
        val ipInt = ((bytes[0].toInt() and 0xFF) shl 24) or
            ((bytes[1].toInt() and 0xFF) shl 16) or
            ((bytes[2].toInt() and 0xFF) shl 8) or
            (bytes[3].toInt() and 0xFF)
        val effectivePrefix = prefix.coerceAtLeast(24)
        val mask = -1 shl (32 - effectivePrefix)
        val network = ipInt and mask
        val broadcast = network or mask.inv()
        val hosts = ArrayList<String>()
        for (host in (network + 1) until broadcast) {
            if (host == ipInt) continue
            hosts.add(intToIp(host))
        }
        return hosts
    }

    private fun intToIp(value: Int): String = buildString {
        append((value ushr 24) and 0xFF)
        append('.')
        append((value ushr 16) and 0xFF)
        append('.')
        append((value ushr 8) and 0xFF)
        append('.')
        append(value and 0xFF)
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

    /**
     * Validates the printer and stores the logical connection.
     *
     * The channel is opened and closed here only to verify the printer is
     * reachable. The actual data operations ([getStatus], [printImage],
     * [printPdf]) open their own channel, use it and close it in a `finally`:
     * this is the pattern recommended by Brother (open -> operation -> close)
     * and it is what keeps the printer from being left "busy" after the first
     * command (QL/BT printers accept a single active connection).
     */
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

        val printer = ConnectedPrinter(model, modelName, connectionType, ip, mac, serial)
        // Reachability probe: open and immediately close a channel.
        val probe = openDriver(printer)
        runCatching { probe.closeChannel() }

        synchronized(this) {
            connectedPrinter = printer
            currentModel = model
        }
        emitState("connected")
        return true
    }

    /**
     * Returns the stored logical connection as a [BrotherPrinter]-compatible
     * map, or null when no printer is connected.
     *
     * The connection is kept until [disconnect] or plugin detach, so this
     * reports the printer even after the caller navigates to another screen —
     * useful to print again without re-running discovery (a connected printer
     * without a proper disconnect is often still "busy" and not discovered).
     */
    private fun getConnectedPrinter(): Map<String, Any?>? {
        val printer = synchronized(this) { connectedPrinter } ?: return null
        return mapOf(
            "model" to printer.modelName,
            "connectionType" to printer.connectionType,
            "ipAddress" to printer.ip,
            "macAddress" to printer.mac,
            "serialNumber" to (printer.serial ?: ""),
        )
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

    /**
     * Opens a fresh channel for [printer] and returns a driver for it.
     */
    private fun openDriver(printer: ConnectedPrinter): PrinterDriver {
        val channel = resolveChannel(
            printer.connectionType,
            printer.ip,
            printer.mac,
            printer.serial,
        )
        val openResult = PrinterDriverGenerator.openChannel(channel)
        val openError = openResult.error
        if (openError != null) {
            throw FlutterFailure(
                mapOpenChannelError(openError.code),
                openError.errorRecoverySuggestion ?: "Unable to open the channel"
            )
        }
        return openResult.driver
            ?: throw FlutterFailure("communicationLost", "Driver not available")
    }

    /**
     * Runs [block] on a freshly opened driver and ALWAYS closes the channel
     * afterwards (also on failure), so the printer is never left "busy" by a
     * stale session.
     */
    private fun <T> withDriver(block: (PrinterDriver) -> T): T {
        val printer = synchronized(this) { connectedPrinter }
            ?: throw FlutterFailure(
                "printerUnreachable",
                "No printer connected: call connect() first"
            )
        val driver = openDriver(printer)
        synchronized(this) { currentDriver = driver }
        try {
            return block(driver)
        } finally {
            synchronized(this) { currentDriver = null }
            runCatching { driver.closeChannel() }
        }
    }

    // ------------------------------------------------------------------
    // Printing
    // ------------------------------------------------------------------

    private fun printImage(call: MethodCall): Map<String, Any?> {
        val imageBytes = call.argument<ByteArray>("imageBytes")
            ?: throw FlutterFailure("invalidArgument", "Missing image bytes")
        val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()
        val model = requireModel()

        val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: throw FlutterFailure("invalidArgument", "Invalid image format")
        return try {
            withDriver { driver ->
                printResultMap(driver.printImage(bitmap, createSettings(options, model)))
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun printPdf(call: MethodCall): Map<String, Any?> {
        val ctx = context ?: throw IllegalStateException("Plugin not initialized")
        val pdfBytes = call.argument<ByteArray>("pdfBytes")
            ?: throw FlutterFailure("invalidArgument", "Missing PDF bytes")
        val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()
        val model = requireModel()

        val file = File(ctx.cacheDir, "brother_print_${System.currentTimeMillis()}.pdf")
        return try {
            file.writeBytes(pdfBytes)
            withDriver { driver ->
                printResultMap(driver.printPDF(file.absolutePath, createSettings(options, model)))
            }
        } finally {
            runCatching { file.delete() }
        }
    }

    private fun requireModel(): PrinterModel =
        synchronized(this) { currentModel } ?: throw FlutterFailure(
            "printerUnreachable",
            "No printer connected: call connect() before printing"
        )

    private fun createSettings(options: Map<String, Any?>, model: PrinterModel): PrintSettings {
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

    // ------------------------------------------------------------------
    // Printer hardware status
    // ------------------------------------------------------------------

    /** Queries the SDK for the current hardware status, or null if disconnected. */
    private fun getStatus(): Map<String, Any?>? {
        if (synchronized(this) { connectedPrinter } == null) return null
        return withDriver { driver -> queryStatus(driver) }
    }

    private fun queryStatus(driver: PrinterDriver): Map<String, Any?> {
        val statusResult: GetStatusResult = driver.getPrinterStatus()
        val getError = statusResult.error
        if (getError != null && getError.code != GetStatusError.ErrorCode.NoError) {
            // The status query itself failed (timeout / printer not found).
            return mapOf(
                "isOk" to false,
                "errorCode" to when (getError.code) {
                    GetStatusError.ErrorCode.Timeout -> "timeout"
                    GetStatusError.ErrorCode.PrinterNotFound -> "printerUnreachable"
                    else -> "unknown"
                },
                "mediaWidthMm" to 0,
                "mediaHeightMm" to 0,
                "isHeightInfinite" to false,
            )
        }
        val status = statusResult.printerStatus
        val media = status?.mediaInfo
        return mapOf(
            "isOk" to (status == null || status.errorCode == PrinterStatus.ErrorCode.NoError),
            "errorCode" to status?.errorCode?.let { statusErrorCodeName(it) },
            "mediaWidthMm" to (media?.width_mm ?: 0),
            "mediaHeightMm" to (media?.height_mm ?: 0),
            "isHeightInfinite" to (media?.isHeightInfinite ?: false),
            // The exact label size the printer detected (e.g. "RollW62",
            // "DieCutW62H100"): pass it as paperType to avoid "wrong roll type".
            "detectedPaperType" to runCatching { media?.getQLLabelSize()?.name }.getOrNull(),
        )
    }

    /** Normalizes an SDK [PrinterStatus.ErrorCode] to a Dart-friendly string. */
    private fun statusErrorCodeName(code: PrinterStatus.ErrorCode): String? = when (code) {
        PrinterStatus.ErrorCode.NoError -> null
        PrinterStatus.ErrorCode.NoPaper -> "outOfPaper"
        PrinterStatus.ErrorCode.CoverOpen -> "coverOpen"
        PrinterStatus.ErrorCode.Busy -> "busy"
        PrinterStatus.ErrorCode.PaperJam -> "paperJam"
        PrinterStatus.ErrorCode.BatteryEmpty -> "batteryEmpty"
        PrinterStatus.ErrorCode.BatteryTrouble -> "batteryTrouble"
        PrinterStatus.ErrorCode.TubeNotDetected -> "tubeNotDetected"
        PrinterStatus.ErrorCode.MotorSlow -> "motorSlow"
        PrinterStatus.ErrorCode.UnsupportedCharger -> "unsupportedCharger"
        PrinterStatus.ErrorCode.IncompatibleOptionalEquipment -> "incompatibleEquipment"
        PrinterStatus.ErrorCode.SystemError -> "systemError"
        PrinterStatus.ErrorCode.AnotherError -> "anotherError"
        else -> "unknown"
    }

    private fun mapOpenChannelError(code: OpenChannelError.ErrorCode): String = when (code) {
        OpenChannelError.ErrorCode.Timeout -> "timeout"
        OpenChannelError.ErrorCode.InsufficientPermissions -> "permissionMissing"
        else -> "communicationLost"
    }

    private fun disconnect() {
        synchronized(this) {
            // Request an abort of any in-flight operation (safe: it only sets
            // the SDK flag; the operation closes its own channel on return).
            currentDriver?.let { runCatching { it.cancelPrinting() } }
            currentDriver = null
            connectedPrinter = null
            currentModel = null
        }
        emitState("disconnected")
    }

    private fun cancelPrinting() {
        // Sets the SDK cancel flag on the in-flight driver (if any). Safe to
        // call while the print thread is blocked; the operation closes its own
        // channel when it returns.
        synchronized(this) { currentDriver }?.let { runCatching { it.cancelPrinting() } }
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
        // Report the stored logical connection, not the transient in-flight
        // driver: subscribing later (e.g. after navigating to another screen)
        // must still report "connected" while the printer is connected.
        emitState(
            if (synchronized(this) { connectedPrinter != null }) "connected" else "disconnected"
        )
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(this) {
            runCatching { currentDriver?.closeChannel() }
            currentDriver = null
            connectedPrinter = null
            currentModel = null
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

/**
 * Minimal SNMPv1 client used by the unicast subnet sweep fallback.
 *
 * It only needs one operation: a single-varbind GET that returns an OCTET
 * STRING (the value of a Brother MIB OID). The request is built by hand
 * (BER/TLV) and the response is walked to extract the last OCTET STRING, which
 * is the varbind value. Failures (timeout, non-SNMP host, malformed packet)
 * return null.
 */
private object SnmpProbe {
    /** Brother private MIB (enterprise 2435): printer model name. */
    const val MODEL_OID = "1.3.6.1.4.1.2435.2.3.9.4.2.1.5.5.1.0"
    /** Standard MIB-II sysDescr, often "Brother QL-820NWB...". */
    const val SYSDESCR_OID = "1.3.6.1.2.1.1.1.0"
    /** Host Resources hrDeviceDescr, also reports the device description. */
    const val HR_DEVICE_DESCR_OID = "1.3.6.1.2.1.25.3.2.1.3.1"
    private const val SNMP_PORT = 161
    private const val COMMUNITY = "public"

    /** Outcome of a probe: whether a UDP reply was received and its value. */
    data class ProbeResult(val responded: Boolean, val value: String?)

    /**
     * Sends an SNMPv1 GET for [oid] to [host].
     *
     * [responded] is true when the host sent back a (parseable) SNMP packet,
     * even if it carried no value (e.g. an error PDU for an unsupported OID);
     * [value] is the OCTET STRING value when present, null otherwise.
     */
    fun probe(host: String, oid: String, timeoutMs: Int): ProbeResult {
        return try {
            val request = buildGetRequest(oid)
            DatagramSocket().use { socket ->
                socket.soTimeout = timeoutMs
                val address = InetAddress.getByName(host)
                socket.send(DatagramPacket(request, request.size, address, SNMP_PORT))
                val buffer = ByteArray(2048)
                val packet = DatagramPacket(buffer, buffer.size)
                socket.receive(packet)
                ProbeResult(true, parseResponse(packet.data, packet.length))
            }
        } catch (e: Exception) {
            ProbeResult(false, null)
        }
    }

    // ------------------------------------------------------------------
    // Encoding (SNMPv1 GET: version 0, community "public", GET PDU)
    // ------------------------------------------------------------------

    private fun buildGetRequest(oid: String): ByteArray {
        val varbind = encodeSequence(encodeOid(oid) + encodeNull())
        val varbindList = encodeSequence(varbind)
        val pdu = encodeTlv(0xA0.toByte(), encodeInteger(1) + encodeInteger(0) + encodeInteger(0) + varbindList)
        val message = encodeInteger(0) + encodeOctetString(COMMUNITY.toByteArray(Charsets.US_ASCII)) + pdu
        return encodeSequence(message)
    }

    private fun encodeSequence(body: ByteArray): ByteArray = encodeTlv(0x30, body)

    private fun encodeOctetString(bytes: ByteArray): ByteArray = encodeTlv(0x04, bytes)

    private fun encodeNull(): ByteArray = byteArrayOf(0x05, 0x00)

    private fun encodeInteger(value: Int): ByteArray {
        var v = value
        val tmp = ByteArray(4)
        var i = tmp.size
        do {
            i--
            tmp[i] = (v and 0xFF).toByte()
            v = v shr 8
        } while (v != 0 && v != -1 && i > 0)
        val first = tmp[i].toInt() and 0xFF
        var start = i
        // Positive values whose top bit is set need a leading 0x00.
        if (value >= 0 && (first and 0x80) != 0) {
            start -= 1
            tmp[start] = 0
        }
        return encodeTlv(0x02, tmp.copyOfRange(start, tmp.size))
    }

    private fun encodeOid(oid: String): ByteArray {
        val parts = oid.split('.').mapNotNull { it.toIntOrNull() }
        val body = ArrayList<Byte>()
        body.addAll(encodeArc(40 * parts[0] + parts[1]).toList())
        for (i in 2 until parts.size) {
            body.addAll(encodeArc(parts[i]).toList())
        }
        return encodeTlv(0x06, body.toByteArray())
    }

    /** Encodes one OID arc in base-128 big-endian with the continuation bit. */
    private fun encodeArc(value: Int): ByteArray {
        val tmp = ByteArray(5)
        var v = value
        var i = tmp.size
        do {
            i--
            tmp[i] = (v and 0x7F).toByte()
            v = v ushr 7
        } while (v > 0)
        for (j in i until tmp.size - 1) {
            tmp[j] = (tmp[j].toInt() or 0x80).toByte()
        }
        return tmp.copyOfRange(i, tmp.size)
    }

    private fun encodeTlv(tag: Byte, value: ByteArray): ByteArray =
        byteArrayOf(tag) + encodeLength(value.size) + value

    private fun encodeLength(length: Int): ByteArray {
        if (length < 128) return byteArrayOf(length.toByte())
        var l = length
        val tmp = ByteArray(4)
        var i = tmp.size
        while (l > 0) {
            i--
            tmp[i] = (l and 0xFF).toByte()
            l = l ushr 8
        }
        val count = tmp.size - i
        val out = ByteArray(count + 1)
        out[0] = (0x80 or count).toByte()
        System.arraycopy(tmp, i, out, 1, count)
        return out
    }

    // ------------------------------------------------------------------
    // Decoding: walk the BER response and return the last OCTET STRING
    // ------------------------------------------------------------------

    private fun parseResponse(data: ByteArray, length: Int): String? {
        val values = ArrayList<String>()
        walkTlv(data, 0, length, values)
        // The first OCTET STRING is always the community; a real response has a
        // second one (the varbind value). An error PDU (unsupported OID) has
        // only the community, so treat it as "no value".
        if (values.size < 2) return null
        val value = values.last()
        return if (value == COMMUNITY) null else value
    }

    private fun walkTlv(data: ByteArray, offset: Int, length: Int, out: MutableList<String>) {
        var pos = offset
        val end = offset + length
        while (pos < end) {
            val tag = data[pos].toInt() and 0xFF
            pos++
            val (len, next) = readLength(data, pos)
            pos = next
            if (pos + len > data.size) return
            when (tag) {
                0x04 -> out.add(String(data, pos, len, Charsets.US_ASCII))
                // 0x30 = SEQUENCE; 0xA0/0xA1/0xA2 = SNMP PDUs (the GetResponse
                // is 0xA2): the varbind value lives inside them.
                0x30, 0xA0, 0xA1, 0xA2 -> walkTlv(data, pos, len, out)
            }
            pos += len
        }
    }

    private fun readLength(data: ByteArray, offset: Int): Pair<Int, Int> {
        val first = data[offset].toInt() and 0xFF
        if ((first and 0x80) == 0) return Pair(first, offset + 1)
        val count = first and 0x7F
        var length = 0
        for (i in 0 until count) {
            length = (length shl 8) or (data[offset + 1 + i].toInt() and 0xFF)
        }
        return Pair(length, offset + 1 + count)
    }
}

