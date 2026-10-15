package com.meshcentral.htcommander

import android.content.pm.ServiceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RadioServiceForegroundTypesTest {
    @Test
    fun `uses microphone type only for microphone input on Android 10 through 13`() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            RadioServiceForegroundTypes.forSdk(29, microphoneActive = true),
        )
        assertEquals(
            0,
            RadioServiceForegroundTypes.forSdk(33, microphoneActive = false),
        )
    }

    @Test
    fun `uses special use for radio recording and microphone type for capture on Android 14`() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            RadioServiceForegroundTypes.forSdk(34, microphoneActive = false),
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            RadioServiceForegroundTypes.forSdk(35, microphoneActive = true),
        )
    }

    @Test
    fun `uses legacy foreground service API before Android 10`() {
        assertNull(RadioServiceForegroundTypes.forSdk(28, microphoneActive = true))
    }
}
