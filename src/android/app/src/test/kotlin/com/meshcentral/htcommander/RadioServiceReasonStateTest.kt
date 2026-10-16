package com.meshcentral.htcommander

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RadioServiceReasonStateTest {
    @Test
    fun `Wi-Fi stays active only while remote web server is enabled`() {
        val state = RadioServiceReasonState()

        assertTrue(state.set(RadioServiceReasonState.REASON_RECORDING, true))
        assertFalse(state.isActive(RadioServiceReasonState.REASON_MICROPHONE))
        assertTrue(state.set(RadioServiceReasonState.REASON_MICROPHONE, true))
        assertTrue(state.isActive(RadioServiceReasonState.REASON_MICROPHONE))
        assertTrue(state.set(RadioServiceReasonState.REASON_MICROPHONE, false))
        assertFalse(state.isActive(RadioServiceReasonState.REASON_MICROPHONE))
        assertFalse(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_RADIO, true))
        assertTrue(state.hasActiveBluetoothSession)
        assertFalse(state.shouldKeepWifiActive)

        // Pending Bluetooth reconnects need process protection in the
        // background, but must not keep Wi-Fi awake like the remote server.
        assertTrue(state.set(RadioServiceReasonState.REASON_RADIO_RECONNECT, true))
        assertTrue(state.hasActiveBluetoothSession)
        assertFalse(state.shouldKeepWifiActive)
        assertTrue(state.set(RadioServiceReasonState.REASON_RADIO_RECONNECT, false))
        assertTrue(state.hasActiveBluetoothSession)

        assertTrue(state.set(RadioServiceReasonState.REASON_NETWORK_SERVICES, true))
        assertFalse(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_SERVER, true))
        assertTrue(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_SERVER, false))
        assertFalse(state.shouldKeepWifiActive)

        assertTrue(state.set(RadioServiceReasonState.REASON_NETWORK_SERVICES, false))
        assertTrue(state.set(RadioServiceReasonState.REASON_RADIO, false))
        assertFalse(state.hasActiveBluetoothSession)
        assertFalse(state.set(RadioServiceReasonState.REASON_RECORDING, false))
    }
}
