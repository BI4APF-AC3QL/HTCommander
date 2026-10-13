package com.meshcentral.htcommander

import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class RfcommConnectionAttemptsTest {
    private val spp = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val audio = UUID.fromString("39144315-32FA-40DB-85ED-FBFEBA2D86E6")

    private class FakeSocket : Closeable {
        val closed = AtomicBoolean(false)
        override fun close() { closed.set(true) }
    }

    @Test
    fun rejectsDuplicateAddressAndServiceUntilAttemptFinishes() {
        val attempts = RfcommConnectionAttempts()

        val first = attempts.begin("aa-bb-cc-dd-ee-ff", spp)
        assertTrue(first != null)
        assertTrue(attempts.begin("AA:BB:CC:DD:EE:FF", spp) == null)

        attempts.finish("AA:BB:CC:DD:EE:FF", spp, first!!)
        assertTrue(attempts.begin("AA:BB:CC:DD:EE:FF", spp) != null)
    }

    @Test
    fun allowsDifferentDevicesAndServicesToConnectIndependently() {
        val attempts = RfcommConnectionAttempts()

        assertTrue(attempts.begin("AA:BB:CC:DD:EE:FF", spp) != null)
        assertTrue(attempts.begin("AA:BB:CC:DD:EE:FF", audio) != null)
        assertTrue(attempts.begin("11:22:33:44:55:66", spp) != null)
    }

    @Test
    fun cancellationClosesInFlightSocketAndPreventsNewSockets() {
        val attempts = RfcommConnectionAttempts()
        val attempt = attempts.begin("AA:BB:CC:DD:EE:FF", spp)!!
        val connectingSocket = FakeSocket()
        assertTrue(attempt.track(connectingSocket))

        attempts.cancel("aa-bb-cc-dd-ee-ff", spp)

        assertTrue(attempt.isCancelled)
        assertTrue(connectingSocket.closed.get())
        val lateSocket = FakeSocket()
        assertFalse(attempt.track(lateSocket))
        assertTrue(lateSocket.closed.get())
    }

    @Test
    fun finishedSocketIsNotClosedByLaterCancellation() {
        val attempts = RfcommConnectionAttempts()
        val attempt = attempts.begin("AA:BB:CC:DD:EE:FF", spp)!!
        val connectedSocket = FakeSocket()
        assertTrue(attempt.track(connectedSocket))
        attempt.release(connectedSocket)

        attempts.cancel("AA:BB:CC:DD:EE:FF", spp)

        assertFalse(connectedSocket.closed.get())
    }
}
