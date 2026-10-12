package com.meshcentral.htcommander

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RadioServiceReasonStateTest {
    @Test
    fun `Wi-Fi stays active only while remote web server is enabled`() {
        val state = RadioServiceReasonState()

        assertTrue(state.set(RadioServiceReasonState.REASON_RECORDING, true))
        assertFalse(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_NETWORK_SERVICES, true))
        assertFalse(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_SERVER, true))
        assertTrue(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_SERVER, false))
        assertFalse(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_NETWORK_SERVICES, false))
        assertFalse(state.set(RadioServiceReasonState.REASON_RECORDING, false))
    }
}
