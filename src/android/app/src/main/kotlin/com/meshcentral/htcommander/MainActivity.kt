package com.meshcentral.htcommander

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

class MainActivity : FlutterActivity() {
    private var bluetoothClassicPlugin: BluetoothClassicPlugin? = null
    private var speechToTextPlugin: AndroidSpeechToTextPlugin? = null
    private var serverLifecycleChannel: MethodChannel? = null
    private var deviceLocationChannel: MethodChannel? = null
    private var deviceLocationUpdatesChannel: EventChannel? = null
    private var deviceLocationUpdates: LocationUpdatesStream? = null

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

        deviceLocationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.htcommander/device_location",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "getCurrentPosition") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                getCurrentPosition(result)
            }
        }

        deviceLocationUpdates = LocationUpdatesStream(applicationContext)
        deviceLocationUpdatesChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.htcommander/device_location_updates",
        ).also { channel -> channel.setStreamHandler(deviceLocationUpdates) }

        serverLifecycleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.htcommander/server_lifecycle",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            val reason = call.argument<String>("reason") ?: "server"
                            if (reason == "location") {
                                PhoneLocationService.start(applicationContext)
                            } else {
                                RadioWebServerService.start(applicationContext, reason)
                            }
                            result.success(true)
                        }
                        "stop" -> {
                            val reason = call.argument<String>("reason") ?: "server"
                            if (reason == "location") {
                                PhoneLocationService.stop(applicationContext)
                            } else {
                                RadioWebServerService.stop(applicationContext, reason)
                            }
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
        bluetoothClassicPlugin?.dispose()
        bluetoothClassicPlugin = null
        serverLifecycleChannel?.setMethodCallHandler(null)
        serverLifecycleChannel = null
        deviceLocationChannel?.setMethodCallHandler(null)
        deviceLocationChannel = null
        deviceLocationUpdatesChannel?.setStreamHandler(null)
        deviceLocationUpdatesChannel = null
        deviceLocationUpdates?.stop()
        deviceLocationUpdates = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun getCurrentPosition(result: MethodChannel.Result) {
        val hasFine = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) {
            result.error("LOCATION_PERMISSION", "Location permission is not granted", null)
            return
        }

        val manager = getSystemService(LOCATION_SERVICE) as LocationManager
        val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
            .filter { name ->
                try { manager.isProviderEnabled(name) } catch (_: Exception) { false }
            }
        if (providers.isEmpty()) {
            result.error("LOCATION_UNAVAILABLE", "No enabled location provider", null)
            return
        }

        val mainHandler = Handler(Looper.getMainLooper())
        var completed = false
        lateinit var listener: LocationListener
        fun finish(location: Location?) {
            if (completed) return
            completed = true
            mainHandler.removeCallbacksAndMessages(null)
            try { manager.removeUpdates(listener) } catch (_: Exception) { }
            if (location == null) {
                result.error("LOCATION_TIMEOUT", "No current location was received", null)
            } else {
                result.success(mapOf(
                    "latitude" to location.latitude,
                    "longitude" to location.longitude,
                    "altitude" to if (location.hasAltitude()) location.altitude else 0.0,
                    "accuracy" to if (location.hasAccuracy()) location.accuracy else null,
                    "timestamp" to location.time,
                ))
            }
        }
        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) = finish(location)
            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) = Unit
            override fun onProviderEnabled(provider: String) = Unit
            override fun onProviderDisabled(provider: String) = Unit
        }
        var requested = false
        var lastError: Exception? = null
        providers.forEach { provider ->
            try {
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                requested = true
            } catch (error: Exception) {
                lastError = error
            }
        }
        if (!requested) {
            val error = lastError
            if (error is SecurityException) {
                result.error("LOCATION_PERMISSION", "Location permission is not granted", null)
            } else {
                result.error("LOCATION_UNAVAILABLE", error?.message ?: "Location unavailable", null)
            }
        } else {
            mainHandler.postDelayed({ finish(null) }, 25_000L)
        }
    }
}

/** Explicitly subscribed Android location updates, owned by the Flutter engine. */
private class LocationUpdatesStream(context: android.content.Context) : EventChannel.StreamHandler {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(
        android.content.Context.LOCATION_SERVICE,
    ) as LocationManager
    private var sink: EventChannel.EventSink? = null
    private var listener: LocationListener? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        sink = events
        val hasFine = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) {
            events.error("LOCATION_PERMISSION", "Location permission is not granted", null)
            return
        }
        val providers = listOf(
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER,
        ).filter { name ->
            try { manager.isProviderEnabled(name) } catch (_: Exception) { false }
        }
        if (providers.isEmpty()) {
            events.error("LOCATION_UNAVAILABLE", "No enabled location provider", null)
            return
        }
        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                sink?.success(mapOf(
                    "latitude" to location.latitude,
                    "longitude" to location.longitude,
                    "altitude" to if (location.hasAltitude()) location.altitude else 0.0,
                    "accuracy" to if (location.hasAccuracy()) location.accuracy else null,
                    "timestamp" to location.time,
                ))
            }
            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) = Unit
            override fun onProviderEnabled(provider: String) = Unit
            override fun onProviderDisabled(provider: String) = Unit
        }
        try {
            providers.forEach { provider ->
                manager.requestLocationUpdates(
                    provider,
                    2_000L,
                    5f,
                    listener!!,
                    Looper.getMainLooper(),
                )
            }
        } catch (error: SecurityException) {
            events.error("LOCATION_PERMISSION", "Location permission is not granted", null)
            stop()
        } catch (error: Exception) {
            events.error("LOCATION_UNAVAILABLE", error.message ?: "Location unavailable", null)
            stop()
        }
    }

    override fun onCancel(arguments: Any?) = stop()

    fun stop() {
        val current = listener
        listener = null
        if (current != null) try { manager.removeUpdates(current) } catch (_: Exception) { }
        sink = null
    }
}
