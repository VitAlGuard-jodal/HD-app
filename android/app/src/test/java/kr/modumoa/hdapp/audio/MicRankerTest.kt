package kr.modumoa.hdapp.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MicRankerTest {
    @Test
    fun carChoosesBuiltInMicFromSevenPleosInputs() {
        val inputs = listOf(
            MicDevice(1, 15, "Built-In Mic"),
            MicDevice(2, 15, "Built-In Back Mic"),
            MicDevice(3, 25, "Remote Submix In"),
            MicDevice(4, 16, "FM Tuner"),
            MicDevice(5, 21, "Tone Generator 0"),
            MicDevice(6, 21, "Tone Generator 1"),
            MicDevice(7, 28, "Echo-Reference Mic"),
        )
        val ranked = MicRanker.rank(MicMode.CAR, inputs)
        assertEquals("Built-In Mic", ranked.first().name)
        assertEquals(listOf(1, 2), ranked.map { it.id })
        assertTrue(ranked.none { it.type in setOf(28, 16, 25, 18, 21) })
    }

    @Test
    fun phonePrefersBluetoothScoOverBuiltInMic() {
        val ranked = MicRanker.rank(MicMode.PHONE, listOf(
            MicDevice(1, 15, "Built-In Mic"), MicDevice(2, 7, "Bluetooth SCO"),
        ))
        assertEquals(7, ranked.first().type)
    }

    @Test
    fun carFallsBackToUsbHeadsetWithoutBuiltInMic() {
        val ranked = MicRanker.rank(MicMode.CAR, listOf(MicDevice(3, 22, "USB Headset")))
        assertEquals(22, ranked.first().type)
    }

    @Test
    fun exclusionsApplyInBothModesAndNoCandidateIsAllowed() {
        val inputs = listOf(28, 16, 25, 18, 21).map { MicDevice(it, it, "제외 장치") }
        MicMode.entries.forEach { assertTrue(MicRanker.rank(it, inputs).isEmpty()) }
    }

    @Test
    fun carKeepsBuiltInAheadOfHeadsetsAndOtherInputs() {
        val inputs = listOf(MicDevice(1, 11, "USB Device"), MicDevice(2, 3, "Wired Headset"), MicDevice(3, 15, "Built-In Mic"))
        assertEquals(listOf(3, 2, 1), MicRanker.rank(MicMode.CAR, inputs).map { it.id })
        assertEquals(listOf(2, 3, 1), MicRanker.rank(MicMode.PHONE, inputs).map { it.id })
        assertEquals(listOf(1, 2, 3), inputs.map { it.id })
    }
}
