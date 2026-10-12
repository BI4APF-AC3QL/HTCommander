package com.meshcentral.htcommander

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class BoundedSerialExecutorTest {
    @Test
    fun preservesOrderAndRejectsWritesWhenQueueIsFull() {
        val executor = BoundedSerialExecutor(capacity = 1, threadName = "writer-test")
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CountDownLatch(2)
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
            assertFalse(executor.execute { order.add(3) })

            release.countDown()
            assertTrue(completed.await(2, TimeUnit.SECONDS))
            assertEquals(listOf(1, 2), order)
        } finally {
            release.countDown()
            executor.close()
        }
    }
}
