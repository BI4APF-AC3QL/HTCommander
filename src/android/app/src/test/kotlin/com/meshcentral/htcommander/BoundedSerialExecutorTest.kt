package com.meshcentral.htcommander

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class BoundedSerialExecutorTest {
    @Test
    fun executesCleanupAwayFromTheSubmittingThread() {
        val executor = BoundedSerialExecutor(capacity = 1, threadName = "cleanup-test")
        val completed = CountDownLatch(1)
        var workerThreadName: String? = null

        try {
            assertTrue(executor.execute {
                workerThreadName = Thread.currentThread().name
                completed.countDown()
            })
            assertTrue(completed.await(2, TimeUnit.SECONDS))
            assertNotEquals(Thread.currentThread().name, workerThreadName)
            assertEquals("cleanup-test", workerThreadName)
        } finally {
            executor.close()
        }
    }

    @Test
    fun shutdownDoesNotWaitForBlockedSocketCleanup() {
        val executor = BoundedSerialExecutor(capacity = 1, threadName = "dispose-test")
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cleanupFinished = CountDownLatch(1)
        val shutdownFinished = CountDownLatch(1)

        try {
            assertTrue(executor.execute {
                started.countDown()
                release.await()
                cleanupFinished.countDown()
            })
            assertTrue(started.await(2, TimeUnit.SECONDS))

            Thread {
                executor.close()
                shutdownFinished.countDown()
            }.start()

            assertTrue(
                "shutdown must return while background cleanup is still blocked",
                shutdownFinished.await(2, TimeUnit.SECONDS),
            )
            assertEquals(1L, cleanupFinished.count)
        } finally {
            release.countDown()
            executor.close()
        }

        assertTrue(cleanupFinished.await(2, TimeUnit.SECONDS))
    }

    @Test
    fun preservesOrderAndRejectsWritesWhenQueueIsFull() {
        val executor = BoundedSerialExecutor(capacity = 1, threadName = "writer-test")
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CountDownLatch(2)
        val overflowReported = CountDownLatch(1)
        val order = Collections.synchronizedList(mutableListOf<Int>())

        try {
            assertTrue(executor.execute {
                started.countDown()
                check(release.await(2, TimeUnit.SECONDS))
                order.add(1)
                completed.countDown()
            })
            assertTrue(started.await(2, TimeUnit.SECONDS))

            assertTrue(executor.execute {
                order.add(2)
                completed.countDown()
            })
            assertFalse(
                executor.execute(
                    task = { order.add(3) },
                    onRejected = { overflowReported.countDown() },
                ),
            )
            assertTrue(overflowReported.await(1, TimeUnit.SECONDS))

            release.countDown()
            assertTrue(completed.await(2, TimeUnit.SECONDS))
            assertEquals(listOf(1, 2), order)
        } finally {
            release.countDown()
            executor.close()
        }
    }
}
