package com.meshcentral.htcommander

import java.util.ArrayDeque

/**
 * Bounds RFCOMM data waiting for delivery from Android's reader thread to the
 * Flutter event channel on the main thread. Audio can discard stale chunks;
 * control bytes must remain ordered, so callers disconnect on overflow.
 */
internal class BoundedBluetoothEventQueue(
    private val maxChunks: Int = 128,
    private val maxBytes: Int = 512 * 1024,
    private val dropOldest: Boolean = false,
) {
    enum class OfferResult { ACCEPTED, DROPPED_OLDEST, REJECTED }

    private val chunks = ArrayDeque<ByteArray>()
    private var bytes = 0
    private var droppedChunks = 0L
    private var droppedBytes = 0L

    init {
        require(maxChunks > 0)
        require(maxBytes > 0)
    }

    @Synchronized
    fun offer(data: ByteArray): OfferResult {
        if (data.isEmpty() || data.size > maxBytes) return OfferResult.REJECTED
        if (!dropOldest && (chunks.size >= maxChunks || bytes + data.size > maxBytes)) {
            return OfferResult.REJECTED
        }

        var dropped = false
        while (chunks.isNotEmpty() &&
            (chunks.size >= maxChunks || bytes + data.size > maxBytes)
        ) {
            if (!dropOldest) return OfferResult.REJECTED
            val removed = chunks.removeFirst()
            bytes -= removed.size
            droppedChunks++
            droppedBytes += removed.size
            dropped = true
        }

        chunks.addLast(data.copyOf())
        bytes += data.size
        return if (dropped) OfferResult.DROPPED_OLDEST else OfferResult.ACCEPTED
    }

    @Synchronized
    fun poll(): ByteArray? {
        val data = chunks.pollFirst() ?: return null
        bytes -= data.size
        return data
    }

    @Synchronized
    fun clear() {
        chunks.clear()
        bytes = 0
    }

    @Synchronized
    fun isEmpty(): Boolean = chunks.isEmpty()

    @Synchronized
    fun queuedBytes(): Int = bytes

    @Synchronized
    fun queuedChunks(): Int = chunks.size

    @Synchronized
    fun droppedChunkCount(): Long = droppedChunks

    @Synchronized
    fun droppedByteCount(): Long = droppedBytes
}
