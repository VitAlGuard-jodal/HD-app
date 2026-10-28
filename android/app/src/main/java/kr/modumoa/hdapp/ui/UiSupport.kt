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
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalRippleConfiguration
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.io.IOException
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kr.modumoa.hdapp.R
import kr.modumoa.hdapp.audio.MicState
import kr.modumoa.hdapp.net.ApiException

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
    iconSize: Dp = IconPrimary,
) {
    require(contentDescription.isNotBlank())
    val scheme = MaterialTheme.colorScheme
    val targetContainer = containerColor ?: when (style) {
        CarButtonStyle.Filled -> scheme.primary
        CarButtonStyle.Tonal -> scheme.surfaceContainerLow
        CarButtonStyle.Outlined -> scheme.surfaceContainerLow
    }
    val targetContent = contentColor ?: when (style) {
        CarButtonStyle.Filled -> scheme.onPrimary
        CarButtonStyle.Tonal -> scheme.onSurface
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
    val borderColor = if (style == CarButtonStyle.Filled) shownContainer else scheme.outline
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
        }
        .modumoaFocusOutline(focused)
        .semantics { this.contentDescription = contentDescription }
    val renderedIcon = modumoaIcon(icon)
    val content: @Composable () -> Unit = {
        if (animateContainerColor) {
            AnimatedContent<ImageVector?>(
                targetState = if (busy) null else renderedIcon,
                transitionSpec = {
                    ((fadeIn(motionTween(MotionNormal)) + scaleIn(motionTween(MotionNormal), initialScale = 0.8f))
                        togetherWith fadeOut(motionTween(MotionFast))).using(null)
                },
                label = "통화 참여·끊기 아이콘",
            ) { targetIcon ->
                if (targetIcon == null) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(IconTertiary),
                        color = LocalContentColor.current,
                        strokeWidth = 2.dp,
                    )
                } else {
                    Icon(targetIcon, contentDescription = null, modifier = Modifier.size(iconSize))
                }
            }
        } else if (busy) {
            CircularProgressIndicator(
                modifier = Modifier.size(IconTertiary),
                color = LocalContentColor.current,
                strokeWidth = 2.dp,
            )
        } else {
            Icon(renderedIcon, contentDescription = null, modifier = Modifier.size(iconSize)) // 장식: 버튼 설명이 뜻을 전달
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
    contentDescription: String?,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    Icon(modumoaIcon(icon), contentDescription, modifier = Modifier.size(IconTertiary), tint = tint)
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
fun ErrorText(message: String?) {
    var lastMessage by remember { mutableStateOf(message.orEmpty()) }
    LaunchedEffect(message) {
        if (!message.isNullOrBlank()) lastMessage = message
    }
    AnimatedVisibility(visible = !message.isNullOrBlank(), enter = MotionReveal, exit = MotionDismiss) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, contentDescription = null, // 장식: 옆 오류 글자가 뜻을 전달
                modifier = Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.onError)
            Text(message?.takeIf { it.isNotBlank() } ?: lastMessage, color = MaterialTheme.colorScheme.onError)
        }
    }
}

@Composable
fun MicStatus(state: MicState, showLevel: Boolean = true, leading: (@Composable () -> Unit)? = null) {
    val device = state.selected?.name
    val dbfs = if (state.dbfs.isFinite()) "${state.dbfs.roundToInt()} dBFS" else "−∞ dBFS"
    val animatedLevel by animateFloatAsState(state.level, motionTween(MotionMicLevel), label = "마이크 입력 레벨")
    if (!showLevel) {
        StatusChip(Icons.Filled.Mic, device ?: "선택된 마이크 없음")
    } else {
        val percentage: @Composable () -> Unit = {
            Text("${(animatedLevel.coerceIn(0f, 1f) * 100).roundToInt()} %",
                style = MaterialTheme.typography.displaySmall)
        }
        if (leading != null) {
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                leading()
                percentage()
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap),
                verticalAlignment = Alignment.CenterVertically) {
                Crossfade(targetState = state.isRecording && device != null,
                    animationSpec = motionTween(MotionFast), label = "마이크 측정 상태") { recording ->
                    StatusIcon(if (recording) Icons.Filled.Mic else Icons.Filled.MicOff,
                        if (recording) "입력 측정 중" else "마이크 꺼짐",
                        if (recording) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(dbfs, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                percentage()
            }
        }
        val gold = MaterialTheme.colorScheme.primary
        val neutral = MaterialTheme.colorScheme.surfaceContainerHigh
        val line = MaterialTheme.colorScheme.outline
        Canvas(Modifier.fillMaxWidth().height(48.dp).semantics {
            contentDescription = "마이크 입력 레벨"
            progressBarRangeInfo = ProgressBarRangeInfo(animatedLevel.coerceIn(0f, 1f), 0f..1f)
        }) {
            val gap = (size.width / 125f).coerceAtMost(9.dp.toPx())
            val segmentWidth = (size.width - gap * 24) / 25
            repeat(25) { index ->
                val origin = Offset(index * (segmentWidth + gap), 0f)
                drawRect(neutral, origin, Size(segmentWidth, size.height))
                val amount = (animatedLevel * 25 - index).coerceIn(0f, 1f)
                if (amount > 0f) drawRect(gold, origin, Size(segmentWidth * amount, size.height))
                drawRect(if (amount > 0f) gold else line, origin + Offset(0.5.dp.toPx(), 0.5.dp.toPx()),
                    Size((segmentWidth - 1.dp.toPx()).coerceAtLeast(0f), size.height - 1.dp.toPx()),
                    style = Stroke(1.dp.toPx()))
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            listOf("0", "50", "100").forEach {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    ErrorText(state.error)
}

@Composable
fun StatusChip(icon: ImageVector, text: String) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = MaterialTheme.shapes.extraLarge, border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) {
        Row(Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(icon, null)
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

const val JoinedRoomReason = "이미 참여 중인 방이 있음 — 나간 뒤 만들 수 있음"

@Composable
fun JoinedRoomNotice() {
    // 조작 가능한 버튼이 아닌 80dp 상태판으로 비활성 사유를 전달한다.
    Surface(Modifier.size(CarTouchTarget), shape = MaterialTheme.shapes.small,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        border = BorderStroke(2.dp, MaterialTheme.colorScheme.outline)) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            StatusIcon(Icons.Filled.Call, JoinedRoomReason, LocalModumoaColors.current.onCall)
        }
    }
}

@Composable
fun CarTextField(
    value: String,
    onValueChange: (String) -> Unit,
    description: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    supportingText: (@Composable () -> Unit)? = null,
    isError: Boolean = false,
) {
    val interactions = remember { MutableInteractionSource() }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(value, onValueChange,
            modifier = Modifier.fillMaxWidth().height(CarTouchTarget).modumoaFieldBorder(interactions, isError)
                .semantics(mergeDescendants = true) { contentDescription = description },
            enabled = enabled, singleLine = true, shape = MaterialTheme.shapes.small,
            colors = modumoaTextFieldColors(), textStyle = MaterialTheme.typography.bodyLarge,
            placeholder = { Text(description, style = MaterialTheme.typography.bodyLarge) },
            leadingIcon = { Icon(modumoaIcon(icon), null, Modifier.size(IconSecondary)) },
            keyboardOptions = keyboardOptions, visualTransformation = visualTransformation,
            interactionSource = interactions, isError = isError)
        supportingText?.invoke()
    }
}

@Composable
fun EmptyListArtwork(icon: ImageVector, contentDescription: String) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(painterResource(R.drawable.brand_guide_star), null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.primary)
        Icon(icon, contentDescription, Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
