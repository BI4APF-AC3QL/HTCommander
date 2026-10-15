package com.meshcentral.htcommander

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/** Keeps the in-process Flutter radio, recorder and LAN web server alive. */
class RadioWebServerService : Service() {
    companion object {
        private const val CHANNEL_ID = "radio_remote_server"
        private const val NOTIFICATION_ID = 8042
        private const val EXTRA_REASON = "reason"
        private const val REASON_SERVER = RadioServiceReasonState.REASON_SERVER
        private const val ACTION_START = "com.htcommander.action.START_RADIO_SERVICE"
        private val lifecycleLock = Any()
        @Volatile
        private var runningInstance: RadioWebServerService? = null
        private val pendingReasons = mutableSetOf<String>()
        private val pendingStartCallbacks = mutableMapOf<String, MutableList<(String?) -> Unit>>()
        private var startRequested = false

        fun ensureNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "HTCommander 电台服务",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "电台连接、远控服务器或接收录音运行时显示"
                setShowBadge(false)
            }
            context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }

        fun start(
            context: Context,
            reason: String = REASON_SERVER,
            onStarted: ((String?) -> Unit)? = null,
        ) {
            var service: RadioWebServerService? = null
            var requestServiceStart = false
            synchronized(lifecycleLock) {
                service = runningInstance
                pendingReasons.add(reason)
                if (service == null) {
                    if (onStarted != null) {
                        pendingStartCallbacks.getOrPut(reason) { mutableListOf() }
                            .add(onStarted)
                    }
                    if (!startRequested) {
                        startRequested = true
                        requestServiceStart = true
                    }
                }
            }
            service?.let {
                it.startReason(reason, onStarted)
                return
            }
            if (!requestServiceStart) return

            val intent = Intent(context, RadioWebServerService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_REASON, reason)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                val failure = error.message ?: "Could not start service"
                val failedReasons = synchronized(lifecycleLock) {
                    startRequested = false
                    pendingReasons.toList().also { pendingReasons.clear() }
                }
                failedReasons.forEach { failedReason ->
                    finishPendingStart(failedReason, failure)
                }
            }
        }

        private fun finishPendingStart(reason: String, error: String?) {
            val callbacks = synchronized(lifecycleLock) {
                pendingStartCallbacks.remove(reason)?.toList().orEmpty()
            }
            callbacks.forEach { it(error) }
        }

        private fun pendingReasonSnapshot(): Set<String> =
            synchronized(lifecycleLock) { pendingReasons.toSet() }

        @Suppress("UNUSED_PARAMETER")
        fun stop(context: Context, reason: String = REASON_SERVER) {
            val service = synchronized(lifecycleLock) {
                pendingReasons.remove(reason)
                runningInstance
            }
            if (service != null) service.stopReason(reason)
            else finishPendingStart(reason, "Service start was cancelled")
        }

    }

    private val reasonState = RadioServiceReasonState()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var idleStopRunnable: Runnable? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        Log.i("HTCommander", "Radio foreground service onCreate entered")
        startForegroundWithCurrentTypes()
        Log.i("HTCommander", "Radio foreground service promoted")
        synchronized(lifecycleLock) {
            runningInstance = this
            startRequested = false
        }

        // Network services and the recorder cannot respond while Android
        // suspends the CPU. Acquire only while a user-enabled feature is active
        // and release it from onDestroy or an explicit stop.
        acquireServiceWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val reason = intent?.getStringExtra(EXTRA_REASON) ?: REASON_SERVER
        Log.d("HTCommander", "Radio foreground service start command: $reason")
        val reasons = pendingReasonSnapshot()
        if (reasons.isEmpty()) {
            finishPendingStart(reason, "Service start was cancelled")
            scheduleIdleStop()
        } else {
            reasons.forEach { startReason(it) }
        }
        // The HTTP listener, recorder and radio bridge live in Flutter's main
        // isolate. A restarted notification-only service cannot restore them.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.d("HTCommander", "Radio foreground service destroyed")
        idleStopRunnable?.let(mainHandler::removeCallbacks)
        idleStopRunnable = null
        synchronized(lifecycleLock) {
            if (runningInstance === this) runningInstance = null
            startRequested = false
        }
        releaseWifiLock()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun stopReason(reason: String) {
        val stillActive = reasonState.set(reason, false)
        Log.d(
            "HTCommander",
            "Radio foreground service released $reason; active=$stillActive",
        )
        if (stillActive) startForegroundWithCurrentTypes()
        updateWifiLock()
        if (stillActive) return
        idleStopRunnable?.let(mainHandler::removeCallbacks)
        idleStopRunnable = null
        stopForegroundAndService()
    }

    private fun startReason(reason: String, onStarted: ((String?) -> Unit)? = null) {
        idleStopRunnable?.let(mainHandler::removeCallbacks)
        idleStopRunnable = null
        val failure = try {
            reasonState.set(reason, true)
            // Recording is started only after microphone permission has been
            // granted. Promote before opening the input so Android can keep the
            // capture alive when the Activity is backgrounded.
            startForegroundWithCurrentTypes()
            updateWifiLock()
            null
        } catch (error: Exception) {
            reasonState.set(reason, false)
            synchronized(lifecycleLock) { pendingReasons.remove(reason) }
            Log.e("HTCommander", "Could not promote radio service for $reason", error)
            try {
                if (reasonState.set(reason, false)) startForegroundWithCurrentTypes()
                else scheduleIdleStop()
                updateWifiLock()
            } catch (fallbackError: Exception) {
                Log.e("HTCommander", "Could not restore radio service type", fallbackError)
            }
            error.message ?: "Could not promote foreground service"
        }
        onStarted?.invoke(failure)
        finishPendingStart(reason, failure)
    }

    private fun scheduleIdleStop() {
        idleStopRunnable?.let(mainHandler::removeCallbacks)
        val stop = Runnable {
            idleStopRunnable = null
            stopForegroundAndService()
        }
        idleStopRunnable = stop
        // Coalesce a start followed immediately by a stop while Android is
        // still completing the foreground-service handshake. This avoids a
        // stop/start race that can leave Android's original startup timeout
        // armed after the service has already posted its notification.
        mainHandler.postDelayed(stop, 1000)
    }

    private fun stopForegroundAndService() {
        if (pendingReasonSnapshot().isNotEmpty()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun startForegroundWithCurrentTypes() {
        val types = RadioServiceForegroundTypes.forSdk(
            Build.VERSION.SDK_INT,
            reasonState.isActive(RadioServiceReasonState.REASON_MICROPHONE),
        )
        if (types != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, buildNotification(), types)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
    }

    // The user-enabled server/recorder must keep the CPU available for its
    // lifetime; onDestroy releases this lock when the foreground service stops.
    @SuppressLint("WakelockTimeout")
    private fun acquireServiceWakeLock() {
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "HTCommander:RadioServer")
            .apply { setReferenceCounted(false); acquire() }
    }

    @Suppress("DEPRECATION")
    private fun updateWifiLock() {
        if (!reasonState.shouldKeepWifiActive) {
            releaseWifiLock()
            return
        }
        if (wifiLock?.isHeld == true) return

        try {
            val manager = getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = manager.createWifiLock(
                WifiManager.WIFI_MODE_FULL,
                "HTCommander:RemoteServer",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: Exception) {
            // Keep the foreground service available even on devices that deny
            // Wi-Fi locks; Android may still maintain the network connection.
            Log.w("HTCommander", "Could not keep Wi-Fi active for remote server", error)
            wifiLock = null
        }
    }

    private fun releaseWifiLock() {
        wifiLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        wifiLock = null
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("HTCommander 电台服务运行中")
            .setContentText("电台连接、远控、网络服务或接收录音正在运行；点此返回应用管理。")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }
}
