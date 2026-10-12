package com.meshcentral.htcommander

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Keeps the in-process Flutter radio, recorder and LAN web server alive. */
class RadioWebServerService : Service() {
    companion object {
        private const val CHANNEL_ID = "radio_remote_server"
        private const val NOTIFICATION_ID = 8042
        private const val EXTRA_REASON = "reason"
        private const val REASON_SERVER = "server"
        private const val REASON_RECORDING = "recording"
        private const val ACTION_START = "com.htcommander.action.START_RADIO_SERVICE"
        private const val ACTION_STOP = "com.htcommander.action.STOP_RADIO_SERVER"

        fun start(context: Context, reason: String = REASON_SERVER) {
            startCommand(context, ACTION_START, reason)
        }

        fun stop(context: Context, reason: String = REASON_SERVER) {
            startCommand(context, ACTION_STOP, reason)
        }

        private fun startCommand(context: Context, action: String, reason: String) {
            val intent = Intent(context, RadioWebServerService::class.java)
                .setAction(action)
                .putExtra(EXTRA_REASON, reason)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

    }

    private val activeReasons = mutableSetOf<String>()
    private var wakeLock: PowerManager.WakeLock? = null

    private fun setReason(reason: String, enabled: Boolean): Boolean {
        if (reason != REASON_SERVER && reason != REASON_RECORDING) {
            return activeReasons.isNotEmpty()
        }
        if (enabled) activeReasons.add(reason) else activeReasons.remove(reason)
        return activeReasons.isNotEmpty()
    }

    override fun onCreate() {
        super.onCreate()
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

        // A LAN listener cannot respond while Android suspends the CPU. Acquire
        // this only while the user has enabled the server, and release it from
        // onDestroy or an explicit stop.
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "HTCommander:RadioServer")
            .apply { setReferenceCounted(false); acquire() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val reason = intent?.getStringExtra(EXTRA_REASON) ?: REASON_SERVER
        val active = when (intent?.action) {
            ACTION_STOP -> setReason(reason, false)
            ACTION_START -> setReason(reason, true)
            else -> setReason(REASON_SERVER, true)
        }
        if (!active) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // The HTTP listener, recorder and radio bridge live in Flutter's main
        // isolate. A restarted notification-only service cannot restore them.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "HTCommander 电台服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "电台远控服务器或接收录音运行时显示"
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
            .setContentText("电台远控或接收录音正在后台运行；点此返回应用管理。")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }
}
