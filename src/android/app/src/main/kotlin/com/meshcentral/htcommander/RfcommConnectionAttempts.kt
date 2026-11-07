package com.meshcentral.htcommander

import java.io.Closeable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Tracks and cancels RFCOMM channel probes for a device/service pair. */
internal class RfcommConnectionAttempts {
    private data class Key(val address: String, val serviceUuid: UUID)

    internal class Attempt {
        private val lock = Any()
        private val sockets = mutableSetOf<Closeable>()

        @Volatile
        var isCancelled: Boolean = false
            private set

        /** Attaches a socket unless cancelled; a rejected socket stays caller-owned. */
        fun track(socket: Closeable): Boolean {
            return synchronized(lock) {
                if (isCancelled) false else sockets.add(socket)
            }
        }

        fun release(socket: Closeable) {
            synchronized(lock) { sockets.remove(socket) }
        }

        fun cancel() {
            val toClose = synchronized(lock) {
                isCancelled = true
                sockets.toList().also { sockets.clear() }
            }
            toClose.forEach(::closeQuietly)
        }

        private fun closeQuietly(socket: Closeable) {
            try {
                socket.close()
            } catch (_: Exception) {
                // Cancellation should not be replaced by a socket-close error.
            }
        }
    }

    private val active = ConcurrentHashMap<Key, Attempt>()

    fun begin(address: String, serviceUuid: UUID): Attempt? {
        val key = key(address, serviceUuid)
        val attempt = Attempt()
        return if (active.putIfAbsent(key, attempt) == null) attempt else null
    }

    fun cancel(address: String, serviceUuid: UUID) {
        active[key(address, serviceUuid)]?.cancel()
    }

    fun finish(address: String, serviceUuid: UUID, attempt: Attempt) {
        active.remove(key(address, serviceUuid), attempt)
    }

    fun cancelAll() {
        active.values.toList().forEach(Attempt::cancel)
        active.clear()
    }

    private fun key(address: String, serviceUuid: UUID): Key =
        Key(address.trim().uppercase().replace('-', ':'), serviceUuid)
}
