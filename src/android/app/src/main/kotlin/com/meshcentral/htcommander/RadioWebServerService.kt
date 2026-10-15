package com.meshcentral.htcommander

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
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
        @Volatile
        private var runningInstance: RadioWebServerService? = null

        fun start(context: Context, reason: String = REASON_SERVER) {
            val intent = Intent(context, RadioWebServerService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_REASON, reason)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context, reason: String = REASON_SERVER) {
            val service = runningInstance
            if (service != null) {
                service.stopReason(reason)
            } else {
                // Stopping an already absent service is safe and avoids trying
                // to promote a background app into a new foreground service.
                context.stopService(Intent(context, RadioWebServerService::class.java))
            }
        }

    }

    private val reasonState = RadioServiceReasonState()
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        runningInstance = this
        ensureNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Network services and the recorder cannot respond while Android
        // suspends the CPU. Acquire only while a user-enabled feature is active
        // and release it from onDestroy or an explicit stop.
        acquireServiceWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val reason = intent?.getStringExtra(EXTRA_REASON) ?: REASON_SERVER
        reasonState.set(
            if (intent?.action == ACTION_START) reason else REASON_SERVER,
            true,
        )
        updateWifiLock()
        // The HTTP listener, recorder and radio bridge live in Flutter's main
        // isolate. A restarted notification-only service cannot restore them.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (runningInstance === this) runningInstance = null
        releaseWifiLock()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun stopReason(reason: String) {
        val stillActive = reasonState.set(reason, false)
        updateWifiLock()
        if (stillActive) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
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

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "HTCommander 电台服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "电台连接、远控服务器或接收录音运行时显示"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
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
