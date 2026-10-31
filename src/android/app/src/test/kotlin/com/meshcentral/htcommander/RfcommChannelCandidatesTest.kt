package com.meshcentral.htcommander

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class RfcommChannelCandidatesTest {
    private val controlService =
        UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val audioService =
        UUID.fromString("39144315-32FA-40DB-85ED-FBFEBA2D86E6")

    @Test
    fun commonlyObservedChannelsAreProbedBeforeExhaustiveFallback() {
        assertEquals(
            listOf(1, 4, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12),
            RfcommChannelCandidates.scanOrder(
                cachedChannel = null,
                prioritizeControlChannels = true,
            ),
        )
    }

    @Test
    fun audioServiceKeepsStandardScanOrder() {
        assertEquals(
            (1..12).toList(),
            RfcommChannelCandidates.scanOrder(cachedChannel = null),
        )
    }

    @Test
    fun cachedChannelIsNotProbedTwiceAndFallbackCoverageIsPreserved() {
        val order = RfcommChannelCandidates.scanOrder(
            cachedChannel = 4,
            prioritizeControlChannels = true,
        )

        assertEquals(11, order.size)
        assertFalse(order.contains(4))
        assertEquals(order.size, order.toSet().size)
        assertTrue((1..12).all { it == 4 || it in order })
    }

    @Test
    fun channelCacheSeparatesServicesAndNormalizesDeviceAddress() {
        assertEquals(
            RfcommChannelCandidates.serviceKey("aa-bb-cc-dd-ee-ff", controlService),
            RfcommChannelCandidates.serviceKey("AA:BB:CC:DD:EE:FF", controlService),
        )
        assertFalse(
            RfcommChannelCandidates.serviceKey("AA:BB:CC:DD:EE:FF", controlService) ==
                RfcommChannelCandidates.serviceKey("AA:BB:CC:DD:EE:FF", audioService),
        )
    }
}
