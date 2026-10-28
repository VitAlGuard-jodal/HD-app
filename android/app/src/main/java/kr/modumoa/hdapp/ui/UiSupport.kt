package kr.modumoa.hdapp.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalRippleConfiguration
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.io.IOException
import kotlin.math.roundToInt
import kr.modumoa.hdapp.R
import kr.modumoa.hdapp.audio.MicState
import kr.modumoa.hdapp.net.ApiException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

val CarTouchTarget = 80.dp
val CarGap = 24.dp
val IconPrimary = 44.dp
val IconSecondary = 36.dp
val IconTertiary = 24.dp

enum class CarButtonStyle { Filled, Tonal, Outlined }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CarIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    busy: Boolean = false,
    style: CarButtonStyle = CarButtonStyle.Tonal,
    containerColor: Color? = null,
    contentColor: Color? = null,
    animateContainerColor: Boolean = false,
    iconSize: Dp = IconSecondary,
) {
    require(contentDescription.isNotBlank())
    val scheme = MaterialTheme.colorScheme
    val targetContainer = containerColor ?: when (style) {
        CarButtonStyle.Filled -> scheme.primary
        CarButtonStyle.Tonal -> scheme.secondaryContainer
        CarButtonStyle.Outlined -> scheme.surface
    }
    val targetContent = contentColor ?: when (style) {
        CarButtonStyle.Filled -> scheme.onPrimary
        CarButtonStyle.Tonal -> scheme.onSecondaryContainer
        CarButtonStyle.Outlined -> scheme.onSurface
    }
    val shownContainer = if (animateContainerColor) {
        animateColorAsState(targetContainer, motionTween(MotionNormal), label = "통화 버튼 배경").value
    } else targetContainer
    val colors = IconButtonDefaults.filledIconButtonColors(
        containerColor = shownContainer,
        contentColor = targetContent,
        // 비활성화해도 확정된 전경·배경 대비는 유지한다.
        disabledContainerColor = shownContainer,
        disabledContentColor = targetContent,
    )
    val interactions = remember { MutableInteractionSource() }
    val pressed by interactions.collectIsPressedAsState()
    val focused by interactions.collectIsFocusedAsState()
    val shape = MaterialTheme.shapes.medium
    val borderColor = if (style == CarButtonStyle.Outlined) scheme.outline else shownContainer
    val buttonModifier = modifier.size(CarTouchTarget)
        .border(2.dp, borderColor, shape)
        .drawWithContent {
            drawContent()
            if (pressed) {
                // 기본 테두리 안쪽에 3dp 누름 윤곽을 그린다.
                val inset = 3.5.dp.toPx()
                val outline = shape.createOutline(Size(size.width - 2 * inset, size.height - 2 * inset), layoutDirection, this)
                translate(inset, inset) { drawOutline(outline, targetContent, style = Stroke(3.dp.toPx())) }
            }
            if (focused) {
                // 클릭 영역은 그대로 두고 바깥쪽에 4dp 키보드 포커스 윤곽을 더한다.
                val outset = 2.dp.toPx()
                val outline = shape.createOutline(Size(size.width + 2 * outset, size.height + 2 * outset), layoutDirection, this)
                translate(-outset, -outset) { drawOutline(outline, scheme.outline, style = Stroke(4.dp.toPx())) }
            }
        }
        .semantics { this.contentDescription = contentDescription }
    val content: @Composable () -> Unit = {
        if (busy) {
            CircularProgressIndicator(
                modifier = Modifier.size(IconTertiary),
                color = LocalContentColor.current,
                strokeWidth = 2.dp,
            )
        } else if (animateContainerColor) {
            AnimatedContent(
                targetState = icon,
                transitionSpec = {
                    ((fadeIn(motionTween(MotionNormal)) + scaleIn(motionTween(MotionNormal), initialScale = 0.8f))
                        togetherWith fadeOut(motionTween(MotionFast))).using(null)
                },
                label = "통화 참여·끊기 아이콘",
            ) { targetIcon ->
                Icon(targetIcon, contentDescription = null, modifier = Modifier.size(iconSize))
            }
        } else {
            Icon(icon, contentDescription = null, modifier = Modifier.size(iconSize)) // 장식: 버튼 설명이 뜻을 전달
        }
    }
    // 누름·포커스는 윤곽으로만 알리고 반투명 리플로 역할색을 바꾸지 않는다.
    CompositionLocalProvider(LocalRippleConfiguration provides null) {
        when (style) {
            CarButtonStyle.Filled -> FilledIconButton(
                onClick = onClick, modifier = buttonModifier, enabled = enabled && !busy,
                shape = shape, colors = colors, interactionSource = interactions, content = content,
            )
            CarButtonStyle.Tonal -> FilledTonalIconButton(
                onClick = onClick, modifier = buttonModifier, enabled = enabled && !busy,
                shape = shape, colors = colors, interactionSource = interactions, content = content,
            )
            CarButtonStyle.Outlined -> OutlinedIconButton(
                onClick = onClick, modifier = buttonModifier, enabled = enabled && !busy,
                shape = shape, colors = colors, border = BorderStroke(2.dp, borderColor),
                interactionSource = interactions, content = content,
            )
        }
    }
}

@Composable
fun StatusIcon(
    icon: ImageVector,
    contentDescription: String,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    Icon(icon, contentDescription, modifier = Modifier.size(IconTertiary), tint = tint)
}

class ActionState(private val scope: CoroutineScope) {
    var busy by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    fun run(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                block()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                error = when (failure) {
                    is ApiException -> if (failure.status == 401) "인증에 실패했습니다. 아이디·비밀번호 또는 로그인 상태를 확인해 주세요." else failure.message
                    is IOException -> "서버에 연결하지 못했습니다. 서버 주소와 네트워크를 확인해 주세요."
                    else -> failure.message
                } ?: "요청을 처리하지 못했습니다. 다시 시도해 주세요."
            } finally {
                busy = false
            }
        }
    }
}

@Composable
fun rememberActionState(): ActionState {
    val scope = rememberCoroutineScope()
    return remember(scope) { ActionState(scope) }
}

@Composable
fun ScreenColumn(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().padding(CarGap), verticalArrangement = Arrangement.spacedBy(CarGap), content = content)
}

@Composable
fun ErrorText(message: String?) {
    var lastMessage by remember { mutableStateOf(message.orEmpty()) }
    LaunchedEffect(message) {
        if (!message.isNullOrBlank()) lastMessage = message
    }
    AnimatedVisibility(visible = !message.isNullOrBlank(), enter = MotionReveal, exit = MotionDismiss) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, contentDescription = null, // 장식: 옆 오류 글자가 뜻을 전달
                modifier = Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.error)
            Text(message?.takeIf { it.isNotBlank() } ?: lastMessage, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
fun MicStatus(state: MicState) {
    val device = state.selected?.let { "${it.type}:${it.name}" }
    val dbfs = if (state.dbfs.isFinite()) "${state.dbfs.roundToInt()} dBFS" else "−∞"
    val animatedLevel by animateFloatAsState(state.level, motionTween(MotionMicLevel), label = "마이크 입력 레벨")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Crossfade(targetState = state.isRecording && device != null,
            animationSpec = motionTween(MotionFast), label = "마이크 측정 상태") { recording ->
            StatusIcon(
                icon = if (recording) Icons.Filled.Mic else Icons.Filled.MicOff,
                contentDescription = if (recording) "입력 측정 중" else "마이크 꺼짐",
                tint = if (recording) MaterialTheme.colorScheme.secondary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (device != null) Text(device, Modifier.weight(1f)) else Spacer(Modifier.weight(1f))
        Text(dbfs)
    }
    LinearProgressIndicator(progress = { animatedLevel }, modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.secondary, trackColor = MaterialTheme.colorScheme.surfaceContainerHighest)
    ErrorText(state.error)
}

@Composable
fun EmptyListArtwork(icon: ImageVector, contentDescription: String) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription, Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Image(painterResource(R.drawable.brand_flower), contentDescription = null, modifier = Modifier.size(96.dp))
    }
}
