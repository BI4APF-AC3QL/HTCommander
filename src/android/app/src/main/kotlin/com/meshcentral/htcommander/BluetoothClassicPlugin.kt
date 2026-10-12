package com.meshcentral.htcommander

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Native Bluetooth Classic (RFCOMM / Serial Port Profile) bridge for Android.
 *
 * Registers the same method/event channels the rest of the app already uses for
 * macOS and Windows so the existing Dart [BluetoothClassicMacOS] bridge and
 * [BluetoothClassicTransport] work unchanged:
 *   - MethodChannel `com.htcommander/bluetooth_classic`
 *   - EventChannel  `com.htcommander/bluetooth_classic_data`   (control channel)
 *   - EventChannel  `com.htcommander/bluetooth_classic_audio`  (BS AOC audio)
 *
 * The control channel (SPP, 0x1101) carries GAIA framed commands. The audio
 * channel uses the vendor "BS AOC" 128-bit UUID. RFCOMM channel numbers are
 * resolved by UUID via SDP (Android's createRfcommSocketToServiceRecord), never
 * by a hardcoded channel number. See docs/radio-bluetooth.md.
 */
class BluetoothClassicPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "BtClassic"
        private const val METHOD_CHANNEL = "com.htcommander/bluetooth_classic"
        private const val DATA_EVENT_CHANNEL = "com.htcommander/bluetooth_classic_data"
        private const val AUDIO_EVENT_CHANNEL = "com.htcommander/bluetooth_classic_audio"
        private const val MAX_WRITE_BYTES = 64 * 1024
        private const val CONNECT_ATTEMPT_TIMEOUT_MS = 8_000L
        private const val CONNECT_TOTAL_TIMEOUT_MS = 45_000L
        private const val DISCONNECT_REQUESTED = "user_requested"
        private const val DISCONNECT_REMOTE_CLOSED = "remote_closed"
        private const val DISCONNECT_READ_FAILED = "read_failed"
        private const val DISCONNECT_WRITE_FAILED = "write_failed"
        private const val DISCONNECT_CONTROL_QUEUE_OVERFLOW =
            "control_queue_overflow"
        private const val AUDIO_OVERRUN_REPORT_INTERVAL_MS = 5_000L

        // Standard Serial Port Profile (control / GAIA).
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        // Vendor "BS AOC" service that carries the SBC audio stream.
        private val AUDIO_UUID: UUID = UUID.fromString("39144315-32FA-40DB-85ED-FBFEBA2D86E6")

        // Stable vendor SDP service UUIDs that uniquely identify a compatible
        // radio. Devices are matched by these identifiers instead of by name,
        // because names change across rebrands and can be truncated by the OS
        // Bluetooth stack (e.g. "UV-P" instead of "UV-PRO"). Only the vendor
        // "BS AOC" service is unique to these radios; generic services (SPP
        // 0x1101, Generic Audio 0x1203) are intentionally excluded.
        private val RADIO_SERVICE_UUIDS: Set<UUID> = setOf(AUDIO_UUID)

        // Remembers the RFCOMM channel that last connected for a given radio
        // address so reconnects can skip the channel scan. The radio's SDP
        // record advertises an unstable channel, so the working channel is
        // discovered by probing; caching it makes later connects near-instant.
        private val lastGoodChannel = ConcurrentHashMap<String, Int>()
    }

    /** Updated by [MainActivity] so runtime permission prompts use the visible Activity. */
    @Volatile
    var activity: Activity? = null

    fun detachActivity(activity: Activity) {
        if (this.activity === activity) this.activity = null
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val dataEventChannel = EventChannel(messenger, DATA_EVENT_CHANNEL)
    private val audioEventChannel = EventChannel(messenger, AUDIO_EVENT_CHANNEL)

    private var dataSink: EventChannel.EventSink? = null
    private var audioSink: EventChannel.EventSink? = null

    private val controlConnections = ConcurrentHashMap<String, RfcommConnection>()
    private val audioConnections = ConcurrentHashMap<String, RfcommConnection>()
    private val lifecycleLock = Any()
    private val connectingSockets = ConcurrentHashMap.newKeySet<BluetoothSocket>()

    @Volatile
    private var disposed = false

    init {
        methodChannel.setMethodCallHandler(this)
        dataEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                dataSink = events
            }

            override fun onCancel(arguments: Any?) {
                dataSink = null
            }
        })
        audioEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                audioSink = events
            }

            override fun onCancel(arguments: Any?) {
                audioSink = null
            }
        })
    }

    private val bluetoothAdapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return context.checkSelfPermission(
            Manifest.permission.BLUETOOTH_CONNECT,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasScanPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return context.checkSelfPermission(
            Manifest.permission.BLUETOOTH_SCAN,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestConnectPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        activity?.requestPermissions(
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            1001,
        )
    }

    private fun normalizeAddress(address: String): String =
        address.uppercase().replace('-', ':')

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("PLUGIN_DISPOSED", "Bluetooth bridge is shutting down", null)
            return
        }
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "getPairedDevices" -> result.success(listDevices(filterCompatible = false))
            "findCompatibleDevices" -> result.success(listDevices(filterCompatible = true))
            "getDeviceNames" -> result.success(deviceNames())
            "connect" -> openRfcomm(call.argument<String>("address"), SPP_UUID, audio = false, result)
            "disconnect" -> {
                disconnect(call.argument<String>("address"), audio = false)
                result.success(true)
            }
            "send" -> send(
                call.argument<String>("address"),
                call.argument("data"),
                audio = false,
                result = result,
            )
            "connectAudio" -> connectAudio(call.argument<String>("address"), result)
            "disconnectAudio" -> {
                disconnect(call.argument<String>("address"), audio = true)
                result.success(true)
            }
            "sendAudio" -> send(
                call.argument<String>("address"),
                call.argument("data"),
                audio = true,
                result = result,
            )
            else -> result.notImplemented()
        }
    }

    /** Releases RFCOMM sockets and channel handlers when Flutter detaches. */
    fun dispose() {
        synchronized(lifecycleLock) {
            if (disposed) return
            disposed = true
            methodChannel.setMethodCallHandler(null)
            dataEventChannel.setStreamHandler(null)
            audioEventChannel.setStreamHandler(null)
            dataSink = null
            audioSink = null

            controlConnections.values.toList().forEach {
                it.close(DISCONNECT_REQUESTED)
            }
            controlConnections.clear()
            audioConnections.values.toList().forEach {
                it.close(DISCONNECT_REQUESTED)
            }
            audioConnections.clear()

            connectingSockets.toList().forEach { socket ->
                try {
                    socket.close()
                } catch (_: IOException) {
                }
            }
            connectingSockets.clear()
        }
    }

    private fun isAvailable(): Boolean {
        val adapter = bluetoothAdapter ?: return false
        return adapter.isEnabled
    }

    private fun listDevices(filterCompatible: Boolean): List<Map<String, Any>> {
        val adapter = bluetoothAdapter ?: return emptyList()
        if (!hasConnectPermission()) {
            requestConnectPermission()
            return emptyList()
        }
        val devices = mutableListOf<Map<String, Any>>()
        val seen = mutableSetOf<String>()
        try {
            for (device in adapter.bondedDevices ?: emptySet()) {
                val name = device.name ?: continue
                val address = normalizeAddress(device.address ?: continue)
                if (seen.contains(address)) continue
                val radioUuids = radioServiceUuids(device)
                if (filterCompatible && radioUuids.isEmpty()) continue
                seen.add(address)
                devices.add(
                    mapOf(
                        "name" to name,
                        "address" to address,
                        "isPaired" to true,
                        "isConnected" to controlConnections.containsKey(address),
                        "serviceUuids" to radioUuids,
                    ),
                )
            }
        } catch (e: SecurityException) {
            requestConnectPermission()
        }
        return devices
    }

    private fun deviceNames(): List<String> {
        return listDevices(filterCompatible = false).mapNotNull { it["name"] as? String }
    }

    /**
     * Returns the lowercase 128-bit UUID strings from the device's cached SDP
     * record that identify it as a compatible radio (i.e. the intersection of
     * the device's advertised services with [RADIO_SERVICE_UUIDS]). Reading
     * [BluetoothDevice.getUuids] uses the pairing-time SDP cache and does not
     * trigger a new SDP query. Returns an empty list when none match.
     */
    private fun radioServiceUuids(device: BluetoothDevice): List<String> {
        val uuids = try {
            device.uuids
        } catch (e: SecurityException) {
            requestConnectPermission()
            null
        } ?: return emptyList()
        return uuids
            .map { it.uuid }
            .filter { it in RADIO_SERVICE_UUIDS }
            .map { it.toString().lowercase() }
            .distinct()
    }

    private fun connectAudio(address: String?, result: MethodChannel.Result) {
        openRfcomm(address, AUDIO_UUID, audio = true, result)
    }

    private fun openRfcomm(
        address: String?,
        uuid: UUID,
        audio: Boolean,
        result: MethodChannel.Result,
    ) {
        if (address == null) {
            result.error("INVALID_ARGS", "Missing address", null)
            return
        }
        val adapter = bluetoothAdapter
        if (adapter == null) {
            result.success(false)
            return
        }
        if (!hasConnectPermission()) {
            requestConnectPermission()
            result.success(false)
            return
        }

        val normalized = normalizeAddress(address)
        val map = if (audio) audioConnections else controlConnections
        if (map.containsKey(normalized)) {
            result.success(true)
            return
        }

        Thread {
            var socket: BluetoothSocket? = null
            try {
                // Cancelling discovery speeds up RFCOMM connects, but it needs
                // BLUETOOTH_SCAN on Android 12+. It is only an optimization, so
                // skip it when the permission is missing rather than failing.
                if (hasScanPermission()) {
                    try {
                        adapter.cancelDiscovery()
                    } catch (_: SecurityException) {
                    }
                }
                val device = adapter.getRemoteDevice(normalized)
                socket = connectSocket(device, uuid)

                val connection = RfcommConnection(normalized, socket, audio)
                val existing = synchronized(lifecycleLock) {
                    connectingSockets.remove(socket)
                    if (disposed) {
                        null
                    } else {
                        map.putIfAbsent(normalized, connection)
                    }
                }
                if (disposed || existing != null) {
                    if (existing == null) {
                        try {
                            socket.close()
                        } catch (_: IOException) {
                        }
                        return@Thread
                    }
                    try {
                        socket.close()
                    } catch (_: IOException) {
                    }
                    mainHandler.post { if (!disposed) result.success(true) }
                    return@Thread
                }
                // Queue the connected marker before starting the reader so a
                // fast radio response cannot overtake it on the Flutter channel.
                postEvent(audio, "connected", normalized, null)
                connection.startReading()
                mainHandler.post { if (!disposed) result.success(true) }
            } catch (e: Exception) {
                socket?.let { candidate ->
                    synchronized(lifecycleLock) { connectingSockets.remove(candidate) }
                }
                try {
                    socket?.close()
                } catch (_: IOException) {
                }
                val message = "${e.javaClass.simpleName}: ${e.message ?: "RFCOMM connect failed"}"
                mainHandler.post {
                    if (!disposed) result.error("CONNECT_FAILED", message, null)
                }
            }
        }.start()
    }

    /**
     * Open and connect an RFCOMM socket, trying several strategies in order.
     *
     * The radios accept the connection only with **null authentication** (the
     * Windows app connects with BluetoothEncryptionAllowNullAuthentication). On
     * Android that maps to the *insecure* RFCOMM socket, so we try the insecure
     * sockets first; the secure variants force authentication the radio rejects.
     *
     * The radio's SPP channel is unstable: its SDP record can advertise a server
     * channel (e.g. 1) that the firmware then refuses with an RFCOMM DM frame
     * (`read failed ... read ret: -1`). So when the UUID/SDP-resolved sockets
     * fail we probe a range of fixed RFCOMM channels and take the first the
     * radio actually accepts. A short delay is inserted between attempts to let
     * the radio reset its RFCOMM state. See docs/radio-bluetooth.md.
     */
    private fun connectSocket(
        device: android.bluetooth.BluetoothDevice,
        uuid: UUID,
    ): BluetoothSocket {
        var lastError: Exception? = null
        val address = device.address
        val deadline = SystemClock.elapsedRealtime() + CONNECT_TOTAL_TIMEOUT_MS

        fun attempt(label: String, factory: () -> BluetoothSocket): BluetoothSocket? {
            var candidate: BluetoothSocket? = null
            return try {
                if (disposed) throw IOException("Bluetooth bridge is shutting down")
                val remainingMs = deadline - SystemClock.elapsedRealtime()
                if (remainingMs <= 0) {
                    throw java.net.SocketTimeoutException(
                        "RFCOMM connection attempts exceeded ${CONNECT_TOTAL_TIMEOUT_MS}ms",
                    )
                }
                candidate = factory()
                synchronized(lifecycleLock) {
                    if (disposed) throw IOException("Bluetooth bridge is shutting down")
                    connectingSockets.add(candidate)
                }
                TimedSocketConnect.connect(
                    socket = candidate,
                    timeoutMs = minOf(CONNECT_ATTEMPT_TIMEOUT_MS, remainingMs),
                    threadName = "HTCommander-BT-connect-${address.takeLast(5)}",
                    connect = { it.connect() },
                    close = { it.close() },
                )
                Log.i(TAG, "RFCOMM connected via $label")
                candidate
            } catch (e: Exception) {
                lastError = e
                if (!disposed) {
                    Log.w(TAG, "RFCOMM attempt $label failed: ${e.javaClass.simpleName}: ${e.message}")
                }
                candidate?.let { socket ->
                    synchronized(lifecycleLock) { connectingSockets.remove(socket) }
                }
                try {
                    candidate?.close()
                } catch (_: IOException) {
                }
                if (!disposed && SystemClock.elapsedRealtime() < deadline &&
                    e !is java.net.SocketTimeoutException
                ) {
                    try {
                        Thread.sleep(250)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return null
                    }
                }
                null
            }
        }

        val insecureByChannel = device.javaClass.getMethod(
            "createInsecureRfcommSocket",
            Int::class.javaPrimitiveType,
        )

        fun tryChannel(channel: Int): BluetoothSocket? =
            attempt("insecure-ch$channel") {
                insecureByChannel.invoke(device, channel) as BluetoothSocket
            }?.also { lastGoodChannel[address] = channel }

        // 0. Fast path: reuse the channel that last worked for this radio so we
        //    skip the full scan on reconnect.
        val cachedChannel = lastGoodChannel[address]
        if (cachedChannel != null) {
            tryChannel(cachedChannel)?.let { return it }
        }

        // 1. UUID/SDP-resolved sockets (channel comes from the radio's SDP
        //    record). Insecure first to match the radio's null-auth requirement.
        attempt("insecure-sdp") {
            device.createInsecureRfcommSocketToServiceRecord(uuid)
        }?.let { return it }
        attempt("secure-sdp") {
            device.createRfcommSocketToServiceRecord(uuid)
        }?.let { return it }

        // 2. Probe fixed RFCOMM channels with an insecure socket. The radio's
        //    SPP channel has been observed on 1 and 4; scan a small range and
        //    take the first the radio accepts.
        for (channel in 1..12) {
            if (channel == cachedChannel) continue // already tried above
            tryChannel(channel)?.let { return it }
        }

        // 3. Final fallback: secure fixed channel 1.
        attempt("secure-ch1") {
            val method = device.javaClass.getMethod(
                "createRfcommSocket",
                Int::class.javaPrimitiveType,
            )
            method.invoke(device, 1) as BluetoothSocket
        }?.let { return it }

        throw lastError ?: IOException("RFCOMM connect failed")
    }

    private fun disconnect(address: String?, audio: Boolean) {
        if (address == null) return
        val normalized = normalizeAddress(address)
        val map = if (audio) audioConnections else controlConnections
        map.remove(normalized)?.close(DISCONNECT_REQUESTED)
    }

    private fun send(
        address: String?,
        data: ByteArray?,
        audio: Boolean,
        result: MethodChannel.Result,
    ) {
        if (address == null || data == null || data.size > MAX_WRITE_BYTES) {
            result.success(false)
            return
        }
        val normalized = normalizeAddress(address)
        val map = if (audio) audioConnections else controlConnections
        val connection = map[normalized]
        if (connection == null) {
            result.success(false)
            return
        }
        val accepted = connection.enqueueWrite(data) { written ->
            mainHandler.post { result.success(written) }
        }
        if (!accepted) result.success(false)
    }

    private fun postEvent(
        audio: Boolean,
        event: String,
        address: String,
        data: ByteArray? = null,
        reason: String? = null,
    ) {
        if (disposed) return
        mainHandler.post {
            if (disposed) return@post
            val sink = if (audio) audioSink else dataSink
            val payload = HashMap<String, Any>()
            payload["event"] = event
            payload["address"] = address
            if (data != null) payload["data"] = data
            if (reason != null) payload["reason"] = reason
            sink?.success(payload)
        }
    }

    /** Owns a single RFCOMM socket and its background read loop. */
    private inner class RfcommConnection(
        private val address: String,
        private val socket: BluetoothSocket,
        private val audio: Boolean,
    ) {
        private val writer = BoundedSerialExecutor(
            capacity = 32,
            threadName = "HTCommander-BT-${address.takeLast(5)}",
        )
        private val pendingData = BoundedBluetoothEventQueue(dropOldest = audio)

        @Volatile
        private var closed = false
        private var readThread: Thread? = null
        private var dataDeliveryScheduled = false
        private var audioOverrunReportPending = false
        private var lastAudioOverrunReportAtMs = 0L
        private var audioDropsReportedChunks = 0L
        private var audioDropsReportedBytes = 0L

        fun startReading() {
            readThread = Thread {
                val buffer = ByteArray(4096)
                val input = try {
                    socket.inputStream
                } catch (e: IOException) {
                    handleClosed(DISCONNECT_READ_FAILED)
                    return@Thread
                }
                var closeReason = DISCONNECT_REMOTE_CLOSED
                while (!closed) {
                    val count = try {
                        input.read(buffer)
                    } catch (e: IOException) {
                        closeReason = DISCONNECT_READ_FAILED
                        break
                    }
                    if (count < 0) break
                    if (count > 0) {
                        enqueueData(buffer.copyOf(count))
                    }
                }
                handleClosed(closeReason)
            }.apply { isDaemon = true; start() }
        }

        /**
         * Keep the Android main-handler queue bounded while Flutter consumes
         * RFCOMM events. Control data is lossless and disconnects on overflow;
         * for audio, stale queued chunks are discarded to favor live playback.
         */
        private fun enqueueData(data: ByteArray) {
            if (closed) return
            when (pendingData.offer(data)) {
                BoundedBluetoothEventQueue.OfferResult.REJECTED -> {
                    if (!audio) {
                        Log.w(TAG, "Control event queue overflow; closing RFCOMM connection")
                        handleClosed(DISCONNECT_CONTROL_QUEUE_OVERFLOW)
                    }
                }
                BoundedBluetoothEventQueue.OfferResult.ACCEPTED,
                BoundedBluetoothEventQueue.OfferResult.DROPPED_OLDEST -> synchronized(this) {
                    if (closed) {
                        // close() may have cleared the queue between the read
                        // loop's initial check and offer().
                        pendingData.clear()
                        return
                    }
                    if (audio &&
                        pendingData.droppedChunkCount() > audioDropsReportedChunks
                    ) {
                        reportAudioOverrunIfNeeded()
                    }
                    if (dataDeliveryScheduled) return
                    dataDeliveryScheduled = true
                    mainHandler.post { deliverNextData() }
                }
            }
        }

        /** Reports intentionally discarded playback backlog to the Dart log. */
        private fun reportAudioOverrunIfNeeded() {
            if (audioOverrunReportPending) return
            val now = SystemClock.elapsedRealtime()
            val delayMs = if (lastAudioOverrunReportAtMs == 0L) {
                0L
            } else {
                (AUDIO_OVERRUN_REPORT_INTERVAL_MS -
                    (now - lastAudioOverrunReportAtMs)).coerceAtLeast(0L)
            }
            audioOverrunReportPending = true
            mainHandler.postDelayed(
                {
                    val payload = synchronized(this) {
                        audioOverrunReportPending = false
                        if (closed) return@synchronized null
                        val nowAtReport = SystemClock.elapsedRealtime()
                        val sink = audioSink
                        if (sink == null) {
                            // Keep the throttle active but retain the counts so
                            // a later listener can see the accumulated loss.
                            lastAudioOverrunReportAtMs = nowAtReport
                            return@synchronized null
                        }
                        val totalChunks = pendingData.droppedChunkCount()
                        val totalBytes = pendingData.droppedByteCount()
                        val droppedChunks = totalChunks - audioDropsReportedChunks
                        val droppedBytes = totalBytes - audioDropsReportedBytes
                        if (droppedChunks <= 0) return@synchronized null
                        audioDropsReportedChunks = totalChunks
                        audioDropsReportedBytes = totalBytes
                        lastAudioOverrunReportAtMs = nowAtReport
                        Pair(
                            sink,
                            mapOf(
                                "event" to "buffer_overrun",
                                "address" to address,
                                "droppedChunks" to droppedChunks,
                                "droppedBytes" to droppedBytes,
                            ),
                        )
                    }
                    if (payload != null) payload.first.success(payload.second)
                },
                delayMs,
            )
        }

        private fun deliverNextData() {
            if (closed) {
                pendingData.clear()
                synchronized(this) { dataDeliveryScheduled = false }
                return
            }
            val data = pendingData.poll()
            if (data == null) {
                synchronized(this) {
                    dataDeliveryScheduled = false
                    // A reader may have enqueued between poll() and this lock.
                    if (!closed && !pendingData.isEmpty()) {
                        dataDeliveryScheduled = true
                        mainHandler.post { deliverNextData() }
                    }
                }
                return
            }

            val sink = if (audio) audioSink else dataSink
            sink?.success(mapOf("event" to "data", "address" to address, "data" to data))

            synchronized(this) {
                if (closed) {
                    pendingData.clear()
                    dataDeliveryScheduled = false
                } else if (pendingData.isEmpty()) {
                    dataDeliveryScheduled = false
                } else {
                    // Drain one chunk per main-loop turn so a burst cannot hold
                    // up Android input, notifications, or Flutter frame work.
                    mainHandler.post { deliverNextData() }
                }
            }
        }

        fun enqueueWrite(data: ByteArray, completion: (Boolean) -> Unit): Boolean {
            if (closed) return false
            val payload = data.copyOf()
            return writer.execute {
                val written = writeNow(payload)
                mainHandler.post { completion(written) }
            }
        }

        private fun writeNow(data: ByteArray): Boolean {
            if (closed) return false
            return try {
                socket.outputStream.write(data)
                socket.outputStream.flush()
                true
            } catch (_: IOException) {
                handleClosed(DISCONNECT_WRITE_FAILED)
                false
            }
        }

        @Synchronized
        private fun handleClosed(reason: String) {
            if (closed) return
            closed = true
            pendingData.clear()
            synchronized(this) { dataDeliveryScheduled = false }
            val map = if (audio) audioConnections else controlConnections
            map.remove(address)
            try {
                socket.close()
            } catch (_: IOException) {
            }
            writer.close()
            postEvent(audio, "disconnected", address, reason = reason)
        }

        @Synchronized
        fun close(reason: String = DISCONNECT_REQUESTED) {
            if (closed) return
            closed = true
            pendingData.clear()
            synchronized(this) { dataDeliveryScheduled = false }
            try {
                socket.close()
            } catch (_: IOException) {
            }
            writer.close()
            postEvent(audio, "disconnected", address, reason = reason)
        }
    }
}
