package com.meshcentral.htcommander

/**
 * Android may recreate a sticky foreground service after reclaiming the app
 * process. Only user-enabled, non-capture sessions are eligible to bootstrap
 * the Flutter host again. Microphone and recording requests are deliberately
 * omitted because Android requires a visible, user-initiated context for
 * resuming those foreground-service types.
 */
internal object RadioServiceRestartPolicy {
    private val RESTORABLE_REASONS = setOf(
        RadioServiceReasonState.REASON_SERVER,
        RadioServiceReasonState.REASON_NETWORK_SERVICES,
    )

    fun restorableReasons(reasons: Set<String>): Set<String> =
        reasons.intersect(RESTORABLE_REASONS)

    fun shouldRestart(reasons: Set<String>): Boolean =
        restorableReasons(reasons).isNotEmpty()
}
