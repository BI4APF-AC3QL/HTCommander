package com.meshcentral.htcommander

import java.lang.reflect.Method

/** Optional hidden-API lookup for the legacy RFCOMM channel fallback. */
internal object RfcommChannelMethod {
    fun find(deviceType: Class<*>): Method? = try {
        deviceType.getMethod(
            "createInsecureRfcommSocket",
            Int::class.javaPrimitiveType,
        )
    } catch (_: Exception) {
        null
    }
}
