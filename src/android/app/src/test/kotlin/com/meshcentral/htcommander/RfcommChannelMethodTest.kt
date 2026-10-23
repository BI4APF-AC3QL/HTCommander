package com.meshcentral.htcommander

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RfcommChannelMethodTest {
    private class DeviceWithChannelFactory {
        fun createInsecureRfcommSocket(channel: Int): Any = channel
    }

    @Test
    fun missingHiddenApiReturnsNullSoPublicSdpCanBeUsed() {
        assertNull(RfcommChannelMethod.find(String::class.java))
    }

    @Test
    fun findsLegacyChannelFactoryWhenAvailable() {
        val method = RfcommChannelMethod.find(DeviceWithChannelFactory::class.java)

        assertEquals("createInsecureRfcommSocket", method?.name)
        assertEquals(1, method?.parameterCount)
    }
}
