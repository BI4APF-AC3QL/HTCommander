package com.meshcentral.htcommander

/** Tracks independently enabled Android foreground-service features. */
internal class RadioServiceReasonState {
    private val activeReasons = mutableSetOf<String>()

    fun set(reason: String, enabled: Boolean): Boolean {
        if (reason !in VALID_REASONS) return activeReasons.isNotEmpty()
        if (enabled) activeReasons.add(reason) else activeReasons.remove(reason)
        return activeReasons.isNotEmpty()
    }

    fun isActive(reason: String): Boolean = reason in activeReasons

    val shouldKeepWifiActive: Boolean
        get() = REASON_SERVER in activeReasons

    companion object {
        const val REASON_RADIO = "radio"
        const val REASON_RADIO_RECONNECT = "radioReconnect"
        const val REASON_SERVER = "server"
        const val REASON_RECORDING = "recording"
        const val REASON_NETWORK_SERVICES = "networkServices"

        private val VALID_REASONS = setOf(
            REASON_RADIO,
            REASON_RADIO_RECONNECT,
            REASON_SERVER,
            REASON_RECORDING,
            REASON_NETWORK_SERVICES,
        )
    }
}
