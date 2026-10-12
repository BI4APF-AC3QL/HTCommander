package com.meshcentral.htcommander

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundedBluetoothEventQueueTest {
    @Test
    fun controlQueuePreservesOrderAndRejectsOverflow() {
        val queue = BoundedBluetoothEventQueue(maxChunks = 2, maxBytes = 6)
        assertEquals(BoundedBluetoothEventQueue.OfferResult.ACCEPTED, queue.offer(byteArrayOf(1, 2, 3)))
        assertEquals(BoundedBluetoothEventQueue.OfferResult.ACCEPTED, queue.offer(byteArrayOf(4, 5, 6)))
        assertEquals(BoundedBluetoothEventQueue.OfferResult.REJECTED, queue.offer(byteArrayOf(7)))
        assertEquals(6, queue.queuedBytes())
        assertEquals(2, queue.queuedChunks())
        assertArrayEquals(byteArrayOf(1, 2, 3), queue.poll())
        assertArrayEquals(byteArrayOf(4, 5, 6), queue.poll())
        assertNull(queue.poll())
    }

    @Test
    fun audioQueueDropsOldestChunksToStayWithinBothLimits() {
        val queue = BoundedBluetoothEventQueue(maxChunks = 2, maxBytes = 5, dropOldest = true)
        assertEquals(BoundedBluetoothEventQueue.OfferResult.ACCEPTED, queue.offer(byteArrayOf(1, 2, 3)))
        assertEquals(BoundedBluetoothEventQueue.OfferResult.ACCEPTED, queue.offer(byteArrayOf(4)))
        assertEquals(BoundedBluetoothEventQueue.OfferResult.DROPPED_OLDEST, queue.offer(byteArrayOf(5, 6, 7)))
        assertEquals(4, queue.queuedBytes())
        assertEquals(2, queue.queuedChunks())
        assertEquals(1L, queue.droppedChunkCount())
        assertEquals(3L, queue.droppedByteCount())
        assertArrayEquals(byteArrayOf(4), queue.poll())
        assertArrayEquals(byteArrayOf(5, 6, 7), queue.poll())
    }

    @Test
    fun oversizedChunkIsRejectedAndClearResetsAccounting() {
        val queue = BoundedBluetoothEventQueue(maxChunks = 2, maxBytes = 3, dropOldest = true)
        assertEquals(BoundedBluetoothEventQueue.OfferResult.REJECTED, queue.offer(byteArrayOf(1, 2, 3, 4)))
        queue.offer(byteArrayOf(1, 2))
        queue.clear()
        assertTrue(queue.isEmpty())
        assertEquals(0, queue.queuedBytes())
        assertEquals(0, queue.queuedChunks())
        assertNull(queue.poll())
    }

    @Test
    fun audioDropMetricsAccumulateAcrossOverrunsAndQueueClear() {
        val queue = BoundedBluetoothEventQueue(maxChunks = 2, maxBytes = 5, dropOldest = true)
        queue.offer(byteArrayOf(1, 2, 3))
        queue.offer(byteArrayOf(4))
        queue.offer(byteArrayOf(5, 6, 7))
        queue.offer(byteArrayOf(8, 9, 10, 11))

        assertEquals(3L, queue.droppedChunkCount())
        assertEquals(7L, queue.droppedByteCount())
        queue.clear()
        assertEquals(3L, queue.droppedChunkCount())
        assertEquals(7L, queue.droppedByteCount())
    }
}
