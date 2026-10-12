package com.meshcentral.htcommander

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Runs socket writes in order without allowing an unbounded backlog. */
internal class BoundedSerialExecutor(
    capacity: Int,
    threadName: String,
) {
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(capacity),
        ThreadFactory { runnable ->
            Thread(runnable, threadName).apply { isDaemon = true }
        },
    )

    fun execute(task: () -> Unit): Boolean = try {
        executor.execute { task() }
        true
    } catch (_: RejectedExecutionException) {
        false
    }

    /** Let queued tasks observe their closed connection and complete callbacks. */
    fun close() {
        executor.shutdown()
    }
}
