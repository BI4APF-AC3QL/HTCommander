package com.meshcentral.htcommander

import androidx.car.app.CarAppService
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/**
 * Entry point for the Android Auto car UI.
 *
 * Declared in AndroidManifest.xml with the `androidx.car.app.CarAppService`
 * intent filter and the `androidx.car.app.category.IOT` category. The host
 * (Android Auto / the Desktop Head Unit) binds to this service and drives the
 * screens returned by [RadioSession].
 */
class RadioCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator {
        // The exported CarAppService is reachable only by hosts whose signing
        // certificates are in AndroidX's maintained Android Auto/Automotive list.
        return HostValidator.Builder(this)
            .addAllowedHosts(R.array.car_host_allowlist)
            .build()
    }

    override fun onCreateSession(): Session = RadioSession()
}
