package com.meshcentral.htcommander

/** Narrow discovery fallback for a bonded N7500 whose SDP cache is empty. */
internal object AndroidClassicRadioIdentity {
    private val n7500Name = Regex("^(?:VR[- ]?)?N7500$", RegexOption.IGNORE_CASE)

    fun isKnownN7500Name(name: String): Boolean = n7500Name.matches(name.trim())
}
