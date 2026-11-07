package com.meshcentral.htcommander

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue
import org.junit.Test

class BluetoothConnectionCleanupTest {
    @Test
    fun blockedSocketCloseDoesNotHoldTheLifecycleLock() {
        val lifecycleLock = Any()
        val closeStarted = CountDownLatch(1)
        val allowCloseToFinish = CountDownLatch(1)
        val lockAcquiredByConnect = CountDownLatch(1)
        val cleanup = Thread {
            removeAndCloseOutsideLock(
                lock = lifecycleLock,
                remove = { "connected socket" },
                close = {
                    closeStarted.countDown()
                    allowCloseToFinish.await()
                },
            )
        }

        try {
            cleanup.start()
            assertTrue(closeStarted.await(1, TimeUnit.SECONDS))

            Thread {
                synchronized(lifecycleLock) { lockAcquiredByConnect.countDown() }
            }.start()

            assertTrue(
                "a new connection must acquire the lock while socket close is blocked",
                lockAcquiredByConnect.await(1, TimeUnit.SECONDS),
            )
        } finally {
            allowCloseToFinish.countDown()
        }
    }
}
