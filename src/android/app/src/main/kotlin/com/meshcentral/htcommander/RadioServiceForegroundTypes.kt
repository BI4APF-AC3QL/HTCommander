package com.meshcentral.htcommander

import android.content.pm.ServiceInfo
import android.os.Build

/** Computes the foreground-service type for the currently active features. */
internal object RadioServiceForegroundTypes {
    /**
     * Android 14 requires an explicit service type; older Android versions do
     * not know the `specialUse` type. A null result means use the two-argument
     * API available before Android 10; zero explicitly clears types on Android
     * 10 through 13 when no microphone capture is active.
     */
    fun forSdk(sdkInt: Int, recordingActive: Boolean): Int? {
        if (sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                (if (recordingActive) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        }
        if (sdkInt >= Build.VERSION_CODES.Q) {
            return if (recordingActive) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                0
            }
        }
        return null
    }
}
