package com.meshcentral.htcommander

/** RFCOMM fallback scan order for radios whose SDP channel is stale. */
internal object RfcommChannelCandidates {
    private val commonlyObservedChannels = listOf(1, 4)

    val probeOrder: List<Int> = (commonlyObservedChannels + (1..12)).distinct()

    /** Returns the remaining channels after an optional cached-channel attempt. */
    fun scanOrder(cachedChannel: Int?): List<Int> =
        probeOrder.filter { it != cachedChannel }
}
