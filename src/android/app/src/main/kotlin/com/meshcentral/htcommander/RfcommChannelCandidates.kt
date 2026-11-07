package com.meshcentral.htcommander

import java.util.UUID

/** RFCOMM fallback scan order for radios whose SDP channel is stale. */
internal object RfcommChannelCandidates {
    internal data class ServiceKey(val address: String, val serviceUuid: UUID)

    fun serviceKey(address: String, serviceUuid: UUID) = ServiceKey(
        address.trim().uppercase().replace('-', ':'),
        serviceUuid,
    )

    /** Returns the remaining channels after an optional cached-channel attempt. */
    fun scanOrder(
        cachedChannel: Int?,
        prioritizeControlChannels: Boolean = false,
    ): List<Int> {
        val preferred = if (prioritizeControlChannels) listOf(1, 4) else emptyList()
        return (preferred + (1..12)).distinct().filter { it != cachedChannel }
    }
}
