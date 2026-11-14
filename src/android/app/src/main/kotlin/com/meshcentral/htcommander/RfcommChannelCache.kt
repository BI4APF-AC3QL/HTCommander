package com.meshcentral.htcommander

import android.content.SharedPreferences
import androidx.core.content.edit
import java.util.UUID

/** Small storage boundary so RFCOMM channel persistence can be JVM-tested. */
internal interface RfcommChannelStore {
    fun read(key: String): Int?
    fun write(key: String, channel: Int)
    fun remove(key: String)
}

/**
 * Remembers the last working channel for each radio address and RFCOMM service.
 * Values are kept in memory for the active Flutter engine and in private app
 * preferences so a process restart does not force the radio through a full scan.
 */
internal class RfcommChannelCache(private val store: RfcommChannelStore) {
    private val channels = mutableMapOf<RfcommChannelCandidates.ServiceKey, Int>()

    @Synchronized
    fun get(address: String, serviceUuid: UUID): Int? {
        val key = RfcommChannelCandidates.serviceKey(address, serviceUuid)
        channels[key]?.let { return it }

        val storageKey = storageKey(key)
        val channel = store.read(storageKey) ?: return null
        if (channel !in MIN_CHANNEL..MAX_CHANNEL) {
            store.remove(storageKey)
            return null
        }
        channels[key] = channel
        return channel
    }

    @Synchronized
    fun remember(address: String, serviceUuid: UUID, channel: Int) {
        require(channel in MIN_CHANNEL..MAX_CHANNEL) {
            "RFCOMM channel must be between $MIN_CHANNEL and $MAX_CHANNEL"
        }
        val key = RfcommChannelCandidates.serviceKey(address, serviceUuid)
        channels[key] = channel
        store.write(storageKey(key), channel)
    }

    /**
     * Removes a cached value after it fails. The expected value prevents a late
     * failure from erasing a newer successful channel for the same service.
     */
    @Synchronized
    fun forget(address: String, serviceUuid: UUID, expectedChannel: Int) {
        val key = RfcommChannelCandidates.serviceKey(address, serviceUuid)
        if (channels[key] != expectedChannel) return
        channels.remove(key)
        store.remove(storageKey(key))
    }

    private fun storageKey(key: RfcommChannelCandidates.ServiceKey): String =
        "channel_${key.address.replace(':', '_')}_${key.serviceUuid}"

    private companion object {
        const val MIN_CHANNEL = 1
        const val MAX_CHANNEL = 30
    }
}

internal class SharedPreferencesRfcommChannelStore(
    private val preferences: SharedPreferences,
) : RfcommChannelStore {
    override fun read(key: String): Int? = try {
        if (preferences.contains(key)) preferences.getInt(key, 0) else null
    } catch (_: ClassCastException) {
        // Remove a malformed value from an older or manually edited preference.
        preferences.edit { remove(key) }
        null
    }

    override fun write(key: String, channel: Int) {
        preferences.edit { putInt(key, channel) }
    }

    override fun remove(key: String) {
        preferences.edit { remove(key) }
    }
}
