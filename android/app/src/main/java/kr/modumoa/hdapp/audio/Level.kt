package kr.modumoa.hdapp.audio

import kotlin.math.log10

// 무음은 음의 무한대로 두고 표시 막대에서 하한(-60 dBFS) 아래를 0으로 제한한다.
fun rmsToDbfs(rms: Int): Double = if (rms <= 0) Double.NEGATIVE_INFINITY else 20.0 * log10(rms / 32768.0)

fun dbfsToLevel(dbfs: Double): Float = ((dbfs + 60.0) / 60.0).coerceIn(0.0, 1.0).toFloat()
