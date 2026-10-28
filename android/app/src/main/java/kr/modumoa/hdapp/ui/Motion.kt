package kr.modumoa.hdapp.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.TweenSpec
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.ui.unit.IntOffset

const val MotionFast = 150
const val MotionNormal = 250
const val MotionBrand = 600
const val MotionMicLevel = 80
const val MotionBloomDelay = 300
const val MotionWordmarkDelay = 450
val MotionEasing = FastOutSlowInEasing

// Compose 기본 시계를 사용해 시스템 MotionDurationScale을 그대로 따른다.
fun <T> motionTween(durationMillis: Int = MotionNormal, delayMillis: Int = 0): TweenSpec<T> =
    tween(durationMillis = durationMillis, delayMillis = delayMillis, easing = MotionEasing)

val MotionReveal = fadeIn(motionTween(MotionFast)) + expandVertically(motionTween(MotionFast))
val MotionDismiss = fadeOut(motionTween(MotionFast)) + shrinkVertically(motionTween(MotionFast))
val MotionItemFade = motionTween<Float>(MotionFast)
val MotionItemPlacement = motionTween<IntOffset>(MotionNormal)

// 중간 탄성은 유지하되 높은 강성으로 300ms 안에 안정되는 짧은 확인 동작을 만든다.
val MotionConnectionSpring = spring<Float>(
    dampingRatio = Spring.DampingRatioMediumBouncy,
    stiffness = Spring.StiffnessHigh,
)
