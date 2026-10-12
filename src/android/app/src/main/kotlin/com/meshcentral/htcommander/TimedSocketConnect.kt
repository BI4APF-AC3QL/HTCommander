package com.meshcentral.htcommander

import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Runs a blocking socket connect away from its caller and closes the socket on timeout. */
internal object TimedSocketConnect {
    fun <T> connect(
        socket: T,
        timeoutMs: Long,
        threadName: String,
        connect: (T) -> Unit,
        close: (T) -> Unit,
    ) {
        require(timeoutMs > 0)
        val task = FutureTask<Unit> { connect(socket) }
        Thread(task, threadName).apply {
            isDaemon = true
            start()
        }

        try {
            task.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (error: TimeoutException) {
            closeQuietly(socket, close)
            task.cancel(true)
            throw SocketTimeoutException("RFCOMM connect exceeded ${timeoutMs}ms")
        } catch (error: ExecutionException) {
            val cause = error.cause
            if (cause is Exception) throw cause
            throw IOException("RFCOMM connect failed", cause)
        } catch (error: InterruptedException) {
            closeQuietly(socket, close)
            task.cancel(true)
            Thread.currentThread().interrupt()
            throw IOException("RFCOMM connect was interrupted", error)
        }
    }

    private fun <T> closeQuietly(socket: T, close: (T) -> Unit) {
        try {
            close(socket)
        } catch (_: Exception) {
            // Preserve the timeout/interruption that caused socket cleanup.
        }
    }
}
