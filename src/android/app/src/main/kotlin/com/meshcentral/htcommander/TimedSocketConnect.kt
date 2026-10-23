package com.meshcentral.htcommander

import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Runs a blocking socket operation away from its caller and closes the socket on timeout. */
internal object TimedSocketConnect {
    fun <T> connect(
        socket: T,
        timeoutMs: Long,
        threadName: String,
        connect: (T) -> Unit,
        close: (T) -> Unit,
    ) = run(
        socket = socket,
        timeoutMs = timeoutMs,
        threadName = threadName,
        operation = connect,
        close = close,
    )

    /** Bounds a blocking socket read/write without running it on the caller. */
    fun <T> run(
        socket: T,
        timeoutMs: Long,
        threadName: String,
        operation: (T) -> Unit,
        close: (T) -> Unit,
    ) {
        require(timeoutMs > 0)
        val task = FutureTask<Unit> { operation(socket) }
        Thread(task, threadName).apply {
            isDaemon = true
            start()
        }

        try {
            task.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (error: TimeoutException) {
            closeInBackground(socket, "$threadName-close", close)
            task.cancel(true)
            throw SocketTimeoutException("RFCOMM connect exceeded ${timeoutMs}ms")
        } catch (error: ExecutionException) {
            closeInBackground(socket, "$threadName-close", close)
            val cause = error.cause
            if (cause is Exception) throw cause
            throw IOException("RFCOMM connect failed", cause)
        } catch (error: InterruptedException) {
            closeInBackground(socket, "$threadName-close", close)
            task.cancel(true)
            Thread.currentThread().interrupt()
            throw IOException("RFCOMM connect was interrupted", error)
        }
    }

    /** BluetoothSocket.close() may block inside some vendor Bluetooth services. */
    fun <T> closeInBackground(socket: T, threadName: String, close: (T) -> Unit) {
        Thread({ closeQuietly(socket, close) }, threadName).apply {
            isDaemon = true
            start()
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
