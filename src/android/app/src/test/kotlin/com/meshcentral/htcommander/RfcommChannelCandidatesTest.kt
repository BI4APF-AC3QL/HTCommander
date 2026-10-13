package com.meshcentral.htcommander

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RfcommChannelCandidatesTest {
    @Test
    fun commonlyObservedChannelsAreProbedBeforeExhaustiveFallback() {
        assertEquals(
            listOf(1, 4, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12),
            RfcommChannelCandidates.probeOrder,
        )
    }

    @Test
    fun cachedChannelIsNotProbedTwiceAndFallbackCoverageIsPreserved() {
        val order = RfcommChannelCandidates.scanOrder(cachedChannel = 4)

        assertEquals(11, order.size)
        assertFalse(order.contains(4))
        assertEquals(order.size, order.toSet().size)
        assertTrue((1..12).all { it == 4 || it in order })
    }
}
