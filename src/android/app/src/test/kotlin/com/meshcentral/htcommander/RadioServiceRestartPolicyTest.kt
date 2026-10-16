package com.meshcentral.htcommander

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RadioServiceRestartPolicyTest {
    @Test
    fun `restores only opted-in web and network services`() {
        val reasons = setOf(
            RadioServiceReasonState.REASON_RADIO,
            RadioServiceReasonState.REASON_RADIO_RECONNECT,
            RadioServiceReasonState.REASON_SERVER,
            RadioServiceReasonState.REASON_NETWORK_SERVICES,
            RadioServiceReasonState.REASON_RECORDING,
            RadioServiceReasonState.REASON_MICROPHONE,
            "unknown",
        )

        assertEquals(
            setOf(
                RadioServiceReasonState.REASON_SERVER,
                RadioServiceReasonState.REASON_NETWORK_SERVICES,
            ),
            RadioServiceRestartPolicy.restorableReasons(reasons),
        )
    }

    @Test
    fun `capture-only work does not request sticky process restart`() {
        assertFalse(
            RadioServiceRestartPolicy.shouldRestart(
                setOf(
                    RadioServiceReasonState.REASON_RECORDING,
                    RadioServiceReasonState.REASON_MICROPHONE,
                ),
            ),
        )
        assertTrue(
            RadioServiceRestartPolicy.shouldRestart(
                setOf(RadioServiceReasonState.REASON_SERVER),
            ),
        )
        assertFalse(
            RadioServiceRestartPolicy.shouldRestart(
                setOf(
                    RadioServiceReasonState.REASON_RADIO,
                    RadioServiceReasonState.REASON_RADIO_RECONNECT,
                ),
            ),
        )
    }
}
