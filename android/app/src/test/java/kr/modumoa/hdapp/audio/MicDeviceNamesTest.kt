package kr.modumoa.hdapp.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class MicDeviceNamesTest {
    @Test
    fun emptyAddressOnlyAddsId() {
        assertEquals("Car on arm64 emulator#56", MicDeviceNames.format("Car on arm64 emulator", "", 56))
    }

    @Test
    fun matchingAddressIsNotRepeated() {
        assertEquals("Built-In Mic#57", MicDeviceNames.format("Built-In Mic", "Built-In Mic", 57))
    }

    @Test
    fun differentAddressIsAddedBeforeId() {
        assertEquals("Car on arm64 emulator · Built-In Back Mic#66",
            MicDeviceNames.format("Car on arm64 emulator", "Built-In Back Mic", 66))
    }
}
