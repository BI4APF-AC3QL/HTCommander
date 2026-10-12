package com.meshcentral.htcommander

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bluetoothClassicPlugin: BluetoothClassicPlugin? = null
    private var speechToTextPlugin: AndroidSpeechToTextPlugin? = null
    private var serverLifecycleChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val plugin = BluetoothClassicPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        plugin.activity = this
        bluetoothClassicPlugin = plugin

        speechToTextPlugin = AndroidSpeechToTextPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )

        serverLifecycleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.htcommander/server_lifecycle",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            RadioWebServerService.start(applicationContext)
                            result.success(true)
                        }
                        "stop" -> {
                            RadioWebServerService.stop(applicationContext)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error(
                        "ANDROID_SERVER_SERVICE",
                        error.message ?: "Could not start the Android server service",
                        null,
                    )
                }
            }
        }

        // Bind the Android Auto bridge so the car UI can mirror channel/APRS
        // state and request channel changes from the Dart side.
        AndroidAutoBridge.attach(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        serverLifecycleChannel?.setMethodCallHandler(null)
        serverLifecycleChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
