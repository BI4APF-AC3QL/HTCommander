package com.meshcentral.htcommander

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors

/** A playback worker may only write to the AudioTrack for its own epoch. */
internal class AudioPlaybackEpoch {
    private var current = 0L

    @Synchronized
    fun start(): Long = ++current

    @Synchronized
    fun invalidate(): Long = ++current

    @Synchronized
    fun isCurrent(epoch: Long): Boolean = current == epoch

    /** Run worker cleanup atomically with respect to start/invalidate. */
    @Synchronized
    fun ifCurrent(epoch: Long, action: () -> Unit): Boolean {
        if (current != epoch) return false
        action()
        return true
    }
}

/** Android PCM playback with selectable AudioTrack output routing. */
class AndroidPcmPlayerPlugin(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioControlExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "HTCommanderAudioControl").apply { isDaemon = true }
    }
    private val queueLock = Any()
    private val pending = LinkedBlockingDeque<ByteArray>()
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    @Volatile private var audioTrack: AudioTrack? = null
    @Volatile private var worker: Thread? = null
    @Volatile private var playing = false
    private val playbackEpoch = AudioPlaybackEpoch()
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private var sampleRate = 0
    private var channelCount = 1
    private var frameBytes = 2
    @Volatile private var feedThresholdFrames = 0
    @Volatile private var pendingBytes = 0

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listDevices" -> result.success(listOutputDevices())
                "setup" -> {
                    val rate = call.argument<Int>("sampleRate") ?: 0
                    val channels = call.argument<Int>("channels") ?: 0
                    val deviceId = call.argument<String>("deviceId") ?: ""
                    runAudioControl(result) {
                        setup(rate, channels, deviceId)
                        true
                    }
                }
                "setFeedThreshold" -> {
                    feedThresholdFrames = call.argument<Int>("threshold") ?: 0
                    result.success(null)
                }
                "start" -> {
                    runAudioControl(result) {
                        startPlayback()
                        null
                    }
                }
                "feed" -> {
                    val bytes = call.argument<ByteArray>("buffer")
                    if (bytes == null) {
                        result.error("InvalidBuffer", "Missing PCM buffer", null)
                    } else {
                        enqueue(bytes)
                        result.success(true)
                    }
                }
                "release" -> {
                    runAudioControl(result) {
                        releasePlayback()
                        null
                    }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("ANDROID_PCM_PLAYER", error.message ?: "Audio playback failed", null)
        }
    }

    private fun runAudioControl(
        result: MethodChannel.Result,
        operation: () -> Any?,
    ) {
        audioControlExecutor.execute {
            try {
                val value = operation()
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error(
                        "ANDROID_PCM_PLAYER",
                        error.message ?: "Audio playback failed",
                        null,
                    )
                }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun listOutputDevices(): List<Map<String, String>> {
        val result = mutableListOf(mapOf("id" to "", "label" to "System default"))
        result += audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .filter { it.isSink }
            .distinctBy { it.id }
            .map { device ->
                val name = device.productName?.toString()?.trim().orEmpty()
                mapOf(
                    "id" to device.id.toString(),
                    "label" to if (name.isNotEmpty()) name else deviceTypeLabel(device.type),
                )
            }
        return result
    }

    private fun deviceTypeLabel(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Phone speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired headset"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB headset"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth audio"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth headset"
        else -> "Audio output ($type)"
    }

    private fun setup(rate: Int, channels: Int, requestedDeviceId: String) {
        require(rate in 8000..192000) { "Unsupported PCM sample rate" }
        require(channels == 1 || channels == 2) { "PCM must be mono or stereo" }
        releasePlayback()

        sampleRate = rate
        channelCount = channels
        frameBytes = channels * 2
        val channelMask = if (channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minimum = AudioTrack.getMinBufferSize(rate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        require(minimum > 0) { "Android could not create a PCM buffer" }
        val bufferSize = maxOf(minimum, rate * frameBytes / 5)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(channelMask)
                    .build(),
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        check(track.state == AudioTrack.STATE_INITIALIZED) {
            track.release()
            "Android audio output could not be initialized"
        }
        if (requestedDeviceId.isNotEmpty()) {
            val selectedId = requestedDeviceId.toIntOrNull()
            val selectedDevice = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.id == selectedId && it.isSink }
            if (selectedDevice != null) track.setPreferredDevice(selectedDevice)
        }
        audioTrack = track
    }

    private fun startPlayback() {
        val track = checkNotNull(audioTrack) { "Call setup before start" }
        if (!playing) {
            val epoch = playbackEpoch.start()
            track.play()
            playing = true
            worker = Thread({ playQueuedAudio(epoch) }, "HTCommanderPcmPlayback").apply {
                priority = Thread.MAX_PRIORITY
                start()
            }
        }
    }

    private fun enqueue(input: ByteArray) {
        check(audioTrack != null) { "Call setup before feeding PCM" }
        if (input.isEmpty()) return
        val alignedSize = input.size - input.size % frameBytes
        if (alignedSize == 0) return
        val bytes = input.copyOfRange(input.size - alignedSize, input.size)
        synchronized(queueLock) {
            var offset = 0
            while (offset < bytes.size) {
                val count = minOf(MAX_CHUNK_BYTES, bytes.size - offset)
                val alignedCount = count - count % frameBytes
                val chunk = bytes.copyOfRange(offset, offset + alignedCount)
                pending.addLast(chunk)
                pendingBytes += chunk.size
                offset += alignedCount
            }
            while (pendingBytes > MAX_PENDING_BYTES && pending.isNotEmpty()) {
                pendingBytes -= pending.removeFirst().size
            }
        }
    }

    private fun playQueuedAudio(epoch: Long) {
        try {
            while (isPlaybackActive(epoch)) {
                val chunk = try {
                    pending.pollFirst(100, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                } ?: continue
                synchronized(queueLock) {
                    pendingBytes = maxOf(0, pendingBytes - chunk.size)
                }

                val track = audioTrack ?: break
                var offset = 0
                while (isPlaybackActive(epoch) && offset < chunk.size) {
                    val written = try {
                        track.write(
                            chunk,
                            offset,
                            chunk.size - offset,
                            AudioTrack.WRITE_BLOCKING,
                        )
                    } catch (_: IllegalStateException) {
                        break
                    }
                    if (written <= 0) break
                    offset += written
                }
                if (!isPlaybackActive(epoch)) break
                val queuedFrames = synchronized(queueLock) { pendingBytes / frameBytes }
                if (queuedFrames <= feedThresholdFrames) {
                    mainHandler.post { eventSink?.success(queuedFrames) }
                }
            }
        } finally {
            playbackEpoch.ifCurrent(epoch) {
                playing = false
                if (worker === Thread.currentThread()) worker = null
            }
        }
    }

    private fun isPlaybackActive(epoch: Long): Boolean =
        playing && playbackEpoch.isCurrent(epoch) && !Thread.currentThread().isInterrupted

    private fun releasePlayback() {
        playing = false
        // Invalidate before releasing the AudioTrack so an old blocking write
        // cannot resume against a newly configured track after a quick restart.
        playbackEpoch.invalidate()
        synchronized(queueLock) {
            pending.clear()
            pendingBytes = 0
        }
        val previousWorker = worker
        worker = null
        previousWorker?.interrupt()
        val track = audioTrack
        audioTrack = null
        try {
            track?.pause()
            track?.flush()
        } catch (_: IllegalStateException) {
            // The playback thread may already have released the native state.
        }
        try {
            track?.release()
        } catch (_: IllegalStateException) {
            // Release is idempotent from the app's point of view.
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "com.htcommander/pcm_player"
        private const val EVENT_CHANNEL = "com.htcommander/pcm_player_feed"
        private const val MAX_PENDING_BYTES = 512 * 1024
        private const val MAX_CHUNK_BYTES = 16 * 1024
    }
}
