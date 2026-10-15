package com.meshcentral.htcommander

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/** Retains the Dart engine and native radio bindings while Android services run. */
class HTCommanderApplication : android.app.Application() {
    private var retainedEngine: FlutterEngine? = null
    private var configuredEngine: FlutterEngine? = null
    private var bluetoothPlugin: BluetoothClassicPlugin? = null
    private var pcmPlayerPlugin: AndroidPcmPlayerPlugin? = null

    @Synchronized
    fun provideFlutterEngine(context: Context): FlutterEngine {
        retainedEngine?.let { return it }
        return FlutterEngine(context.applicationContext, null, false).also {
            // This engine is created outside FlutterActivity, so register the
            // pubspec plugins explicitly before the Activity attaches to it.
            GeneratedPluginRegistrant.registerWith(it)
            retainedEngine = it
        }
    }

    @Synchronized
    fun configureFlutterEngine(engine: FlutterEngine, activity: MainActivity) {
        if (configuredEngine === engine) {
            bluetoothPlugin?.activity = activity
            return
        }
        check(retainedEngine === engine) { "Unexpected FlutterEngine supplied to MainActivity" }

        val appContext = applicationContext
        val messenger = engine.dartExecutor.binaryMessenger
        bluetoothPlugin = BluetoothClassicPlugin(appContext, messenger).also {
            it.activity = activity
        }
        pcmPlayerPlugin = AndroidPcmPlayerPlugin(appContext, messenger)
        AndroidSpeechToTextPlugin(appContext, messenger)

        MethodChannel(messenger, "com.htcommander/android_device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "com.htcommander/device_location")
            .setMethodCallHandler { call, result ->
                if (call.method != "getCurrentPosition") {
                    result.notImplemented()
                } else {
                    getCurrentPosition(appContext, result)
                }
            }

        EventChannel(messenger, "com.htcommander/device_location_updates")
            .setStreamHandler(LocationUpdatesStream(appContext))

        MethodChannel(messenger, "com.htcommander/server_lifecycle")
            .setMethodCallHandler { call, result ->
                try {
                    val reason = call.argument<String>("reason") ?: "server"
                    when (call.method) {
                        "start" -> {
                            if (reason == "location") {
                                PhoneLocationService.start(appContext)
                                result.success(true)
                            } else {
                                RadioWebServerService.start(appContext, reason) { error ->
                                    if (error == null) {
                                        result.success(true)
                                    } else {
                                        result.error("ANDROID_SERVER_SERVICE", error, null)
                                    }
                                }
                            }
                        }
                        "stop" -> {
                            if (reason == "location") {
                                PhoneLocationService.stop(appContext)
                            } else {
                                RadioWebServerService.stop(appContext, reason)
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error(
                        "ANDROID_SERVER_SERVICE",
                        error.message ?: "Could not update the Android foreground service",
                        null,
                    )
                }
            }

        AndroidAutoBridge.attach(messenger)
        configuredEngine = engine
    }

    @Synchronized
    fun detachActivity(activity: MainActivity) {
        bluetoothPlugin?.detachActivity(activity)
    }
}
