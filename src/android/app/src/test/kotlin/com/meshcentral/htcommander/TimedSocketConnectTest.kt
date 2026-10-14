package com.meshcentral.htcommander

import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TimedSocketConnectTest {
    private class FakeSocket {
        val closed = AtomicBoolean(false)
    }

    @Test
    fun `successful connect returns without closing socket`() {
        val socket = FakeSocket()
        var connected = false

        TimedSocketConnect.connect(
            socket = socket,
            timeoutMs = 1_000,
            threadName = "connect-success-test",
            connect = { connected = true },
            close = { it.closed.set(true) },
        )

        assertTrue(connected)
        assertFalse(socket.closed.get())
    }

    @Test
    fun `timed out connect closes socket and interrupts worker`() {
        val socket = FakeSocket()
        val workerExited = CountDownLatch(1)
        val started = CountDownLatch(1)
        val closed = CountDownLatch(1)

        try {
            TimedSocketConnect.connect(
                socket = socket,
                timeoutMs = 50,
                threadName = "connect-timeout-test",
                connect = {
                    started.countDown()
                    try {
                        CountDownLatch(1).await()
                    } finally {
                        workerExited.countDown()
                    }
                },
                close = {
                    it.closed.set(true)
                    closed.countDown()
                },
            )
            throw AssertionError("Expected a connection timeout")
        } catch (_: SocketTimeoutException) {
            // Expected.
        }

        assertTrue(started.await(1, TimeUnit.SECONDS))
        assertTrue(closed.await(1, TimeUnit.SECONDS))
        assertTrue(socket.closed.get())
        assertTrue(workerExited.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun `timeout does not wait for a vendor socket close that blocks`() {
        val socket = FakeSocket()
        val closeStarted = CountDownLatch(1)
        val allowCloseToReturn = CountDownLatch(1)
        val workerExited = CountDownLatch(1)
        val caller = Executors.newSingleThreadExecutor()
        val outcome = java.util.concurrent.atomic.AtomicReference<Throwable?>()
        val future = caller.submit {
            try {
                TimedSocketConnect.connect(
                    socket = socket,
                    timeoutMs = 50,
                    threadName = "blocked-close-test",
                    connect = {
                        try {
                            CountDownLatch(1).await()
                        } finally {
                            workerExited.countDown()
                        }
                    },
                    close = {
                        closeStarted.countDown()
                        allowCloseToReturn.await()
                        it.closed.set(true)
                    },
                )
            } catch (error: Throwable) {
                outcome.set(error)
            }
        }

        try {
            future.get(1, TimeUnit.SECONDS)
            assertTrue(outcome.get() is SocketTimeoutException)
            assertTrue(closeStarted.await(1, TimeUnit.SECONDS))
            assertTrue(workerExited.await(1, TimeUnit.SECONDS))
        } finally {
            allowCloseToReturn.countDown()
            caller.shutdownNow()
        }
    }

    @Test
    fun `connect error is returned to the channel caller`() {
        val socket = FakeSocket()
        val expected = IOException("radio rejected RFCOMM")

        try {
            TimedSocketConnect.connect(
                socket = socket,
                timeoutMs = 1_000,
                threadName = "connect-error-test",
                connect = { throw expected },
                close = { it.closed.set(true) },
            )
            throw AssertionError("Expected the connection error")
        } catch (error: IOException) {
            assertEquals(expected.message, error.message)
        }
    }
}
