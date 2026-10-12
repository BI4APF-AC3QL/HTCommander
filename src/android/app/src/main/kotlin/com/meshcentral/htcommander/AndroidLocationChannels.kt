package com.meshcentral.htcommander

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

internal fun getCurrentPosition(context: Context, result: MethodChannel.Result) {
    val hasFine = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED
    val hasCoarse = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.ACCESS_COARSE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED
    if (!hasFine && !hasCoarse) {
        result.error("LOCATION_PERMISSION", "Location permission is not granted", null)
        return
    }

    val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
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

/** Location event stream uses the application context and survives Activity detach. */
internal class LocationUpdatesStream(context: Context) : EventChannel.StreamHandler {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
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
