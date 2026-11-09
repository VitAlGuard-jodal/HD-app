package kr.modumoa.unavonoise

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

class SoftFloor {
    private val delay = FloatArray(DELAY_FRAMES * FRAME_SIZE)
    private var delayIndex = 0
    private var g = 0f

    fun apply(input: FloatArray, output: FloatArray, n: Int) {
        if (n <= 0) return

        var sumSquares = 0.0
        for (i in 0 until n) {
            val sample = input[i].toDouble()
            sumSquares += sample * sample
        }
        val rIn = sqrt(sumSquares / n).toFloat()
        val gRaw = min(MAX_MIX, TARGET_RMS / max(rIn, 1f))
        if (gRaw < g) {
            g = gRaw
        } else {
            g += (gRaw - g) * MIX_RISE
        }

        for (i in 0 until n) {
            // RNNoise 출력의 960 샘플 지연에 입력 사본을 맞춘다.
            val inD = delay[delayIndex]
            delay[delayIndex] = input[i]
            output[i] += g * inD
            delayIndex++
            if (delayIndex == delay.size) delayIndex = 0
        }
    }

    fun reset() {
        delay.fill(0f)
        delayIndex = 0
        g = 0f
    }

    companion object {
        const val FRAME_SIZE = 480
        private const val DELAY_FRAMES = 2
        const val TARGET_FLOOR_DBFS = -63f
        const val MAX_MIX = 0.5f
        const val MIX_RISE = 0.2f
        private val TARGET_RMS = 32768f * 10f.pow(TARGET_FLOOR_DBFS / 20f)
    }
}
