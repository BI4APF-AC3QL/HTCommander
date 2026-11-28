package com.meshcentral.htcommander

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioPlaybackEpochTest {
    @Test
    fun invalidatingPlaybackPreventsTheOldWorkerFromResumingAfterRestart() {
        val playback = AudioPlaybackEpoch()
        val oldWorker = playback.start()

        playback.invalidate()
        val replacementWorker = playback.start()

        assertFalse(playback.isCurrent(oldWorker))
        assertTrue(playback.isCurrent(replacementWorker))

        var oldCleanupRan = false
        assertFalse(playback.ifCurrent(oldWorker) { oldCleanupRan = true })
        assertFalse(oldCleanupRan)

        var replacementCleanupRan = false
        assertTrue(playback.ifCurrent(replacementWorker) { replacementCleanupRan = true })
        assertTrue(replacementCleanupRan)
    }
}
