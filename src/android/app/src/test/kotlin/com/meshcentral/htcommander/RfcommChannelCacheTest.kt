package com.meshcentral.htcommander

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RfcommChannelCacheTest {
    private val controlService =
        UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val audioService =
        UUID.fromString("39144315-32FA-40DB-85ED-FBFEBA2D86E6")
    private val store = MemoryStore()

    @Test
    fun successfulChannelIsAvailableAfterCacheInstanceIsRecreated() {
        val firstRun = RfcommChannelCache(store)
        firstRun.remember("aa-bb-cc-dd-ee-ff", controlService, 4)

        val afterProcessRestart = RfcommChannelCache(store)

        assertEquals(4, afterProcessRestart.get("AA:BB:CC:DD:EE:FF", controlService))
    }

    @Test
    fun failedCachedChannelIsRemovedWithoutTouchingOtherRadioServices() {
        val cache = RfcommChannelCache(store)
        cache.remember("AA:BB:CC:DD:EE:FF", controlService, 4)
        cache.remember("AA:BB:CC:DD:EE:FF", audioService, 2)

        cache.forget("aa-bb-cc-dd-ee-ff", controlService, expectedChannel = 4)

        assertNull(cache.get("AA:BB:CC:DD:EE:FF", controlService))
        assertEquals(2, cache.get("AA:BB:CC:DD:EE:FF", audioService))
    }

    @Test
    fun lateFailureCannotEraseAChannelRememberedByANewerConnection() {
        val cache = RfcommChannelCache(store)
        cache.remember("AA:BB:CC:DD:EE:FF", controlService, 4)
        cache.remember("AA:BB:CC:DD:EE:FF", controlService, 1)

        cache.forget("AA:BB:CC:DD:EE:FF", controlService, expectedChannel = 4)

        assertEquals(1, cache.get("AA:BB:CC:DD:EE:FF", controlService))
    }

    @Test
    fun invalidPersistedChannelIsDiscarded() {
        store.write("channel_AA_BB_CC_DD_EE_FF_$controlService", 31)
        val cache = RfcommChannelCache(store)

        assertNull(cache.get("AA:BB:CC:DD:EE:FF", controlService))
        assertEquals(emptyMap<String, Int>(), store.values)
    }

    private class MemoryStore : RfcommChannelStore {
        val values = mutableMapOf<String, Int>()

        override fun read(key: String): Int? = values[key]
        override fun write(key: String, channel: Int) {
            values[key] = channel
        }
        override fun remove(key: String) {
            values.remove(key)
        }
    }
}
