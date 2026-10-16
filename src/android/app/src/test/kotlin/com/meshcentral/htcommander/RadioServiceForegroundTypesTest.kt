package com.meshcentral.htcommander

import android.content.pm.ServiceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RadioServiceForegroundTypesTest {
    @Test
    fun `uses microphone and connected device types for active features on Android 10 through 13`() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            RadioServiceForegroundTypes.forSdk(29, microphoneActive = true),
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            RadioServiceForegroundTypes.forSdk(
                33,
                microphoneActive = false,
                bluetoothSessionActive = true,
            ),
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            RadioServiceForegroundTypes.forSdk(
                33,
                microphoneActive = true,
                bluetoothSessionActive = true,
            ),
        )
        assertEquals(
            0,
            RadioServiceForegroundTypes.forSdk(33, microphoneActive = false),
        )
    }

    @Test
    fun `uses special use, connected device and microphone types on Android 14`() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            RadioServiceForegroundTypes.forSdk(34, microphoneActive = false),
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            RadioServiceForegroundTypes.forSdk(
                34,
                microphoneActive = false,
                bluetoothSessionActive = true,
            ),
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            RadioServiceForegroundTypes.forSdk(
                35,
                microphoneActive = true,
                bluetoothSessionActive = true,
            ),
        )
    }

    @Test
    fun `uses legacy foreground service API before Android 10`() {
        assertNull(
            RadioServiceForegroundTypes.forSdk(
                28,
                microphoneActive = true,
                bluetoothSessionActive = true,
            ),
        )
    }
}
