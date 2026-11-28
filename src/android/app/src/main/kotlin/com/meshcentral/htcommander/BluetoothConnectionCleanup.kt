package com.meshcentral.htcommander

/** Removes a connection under its lifecycle lock, then runs blocking cleanup unlocked. */
internal fun <T> removeAndCloseOutsideLock(
    lock: Any,
    remove: () -> T?,
    close: (T) -> Unit,
) {
    val connection = synchronized(lock, remove)
    connection?.let(close)
}
