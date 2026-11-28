package com.meshcentral.htcommander

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidClassicRadioIdentityTest {
    @Test
    fun recognizesOnlyExplicitN7500NamesWhenSdpIsMissing() {
        assertTrue(AndroidClassicRadioIdentity.isKnownN7500Name("VR-N7500"))
        assertTrue(AndroidClassicRadioIdentity.isKnownN7500Name(" n7500 "))
        assertTrue(AndroidClassicRadioIdentity.isKnownN7500Name("VR N7500"))
        assertFalse(AndroidClassicRadioIdentity.isKnownN7500Name("VR-N750"))
        assertFalse(AndroidClassicRadioIdentity.isKnownN7500Name("N7500 headset"))
        assertFalse(AndroidClassicRadioIdentity.isKnownN7500Name("Other radio"))
    }
}
