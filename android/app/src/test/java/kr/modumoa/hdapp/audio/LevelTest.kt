package kr.modumoa.hdapp.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LevelTest {
    @Test
    fun silenceHasZeroLevel() {
        val dbfs = rmsToDbfs(0)
        assertTrue(dbfs == Double.NEGATIVE_INFINITY)
        assertEquals(0f, dbfsToLevel(dbfs), 0f)
    }

    @Test
    fun fullScaleHasZeroDbfsAndFullLevel() {
        val dbfs = rmsToDbfs(32768)
        assertEquals(0.0, dbfs, 0.0001)
        assertEquals(1f, dbfsToLevel(dbfs), 0f)
    }

    @Test
    fun nearMinusSixtyDbfsHasAlmostZeroLevel() {
        val dbfs = rmsToDbfs(33)
        assertEquals(-60.0, dbfs, 0.1)
        assertEquals(0f, dbfsToLevel(dbfs), 0.02f)
    }

    @Test
    fun nearMinusThirtyDbfsHasHalfLevel() {
        val dbfs = rmsToDbfs(1037)
        assertEquals(-30.0, dbfs, 0.1)
        assertEquals(0.5f, dbfsToLevel(dbfs), 0.02f)
    }
}
