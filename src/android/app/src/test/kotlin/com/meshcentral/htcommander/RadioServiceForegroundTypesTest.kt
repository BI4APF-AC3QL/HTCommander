package com.meshcentral.htcommander

import android.content.pm.ServiceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RadioServiceForegroundTypesTest {
    @Test
    fun `uses microphone type for recording on Android 10 through 13`() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            RadioServiceForegroundTypes.forSdk(29, recordingActive = true),
        )
        assertEquals(
            0,
            RadioServiceForegroundTypes.forSdk(33, recordingActive = false),
        )
    }

    @Test
    fun `combines special use and microphone types on Android 14 and later`() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            RadioServiceForegroundTypes.forSdk(34, recordingActive = false),
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            RadioServiceForegroundTypes.forSdk(35, recordingActive = true),
        )
    }

    @Test
    fun `uses legacy foreground service API before Android 10`() {
        assertNull(RadioServiceForegroundTypes.forSdk(28, recordingActive = true))
    }
}
