package kr.modumoa.hdapp.ui

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
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.io.IOException
import kotlin.math.roundToInt
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
    iconSize: Dp = IconSecondary,
) {
    require(contentDescription.isNotBlank())
    val buttonModifier = modifier.size(CarTouchTarget).semantics {
        this.contentDescription = contentDescription
    }
    val defaultColors = when (style) {
        CarButtonStyle.Filled -> IconButtonDefaults.filledIconButtonColors()
        CarButtonStyle.Tonal -> IconButtonDefaults.filledTonalIconButtonColors()
        CarButtonStyle.Outlined -> IconButtonDefaults.outlinedIconButtonColors()
    }
    val colors = if (containerColor == null) defaultColors else defaultColors.copy(
        containerColor = containerColor,
        contentColor = if (containerColor == MaterialTheme.colorScheme.error) {
            MaterialTheme.colorScheme.onError
        } else Color.White,
    )
    val content: @Composable () -> Unit = {
        if (busy) {
            CircularProgressIndicator(
                modifier = Modifier.size(IconTertiary),
                color = LocalContentColor.current,
                strokeWidth = 2.dp,
            )
        } else {
            Icon(icon, contentDescription = null, modifier = Modifier.size(iconSize)) // 장식: 버튼 설명이 뜻을 전달
        }
    }
    when (style) {
        CarButtonStyle.Filled -> FilledIconButton(
            onClick = onClick, modifier = buttonModifier, enabled = enabled && !busy,
            colors = colors, content = content,
        )
        CarButtonStyle.Tonal -> FilledTonalIconButton(
            onClick = onClick, modifier = buttonModifier, enabled = enabled && !busy,
            colors = colors, content = content,
        )
        CarButtonStyle.Outlined -> OutlinedIconButton(
            onClick = onClick, modifier = buttonModifier, enabled = enabled && !busy,
            colors = colors, content = content,
        )
    }
}

@Composable
fun StatusIcon(
    icon: ImageVector,
    contentDescription: String,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    Icon(icon, contentDescription, modifier = Modifier.size(IconSecondary), tint = tint)
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
    if (!message.isNullOrBlank()) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, contentDescription = null, // 장식: 옆 오류 글자가 뜻을 전달
                modifier = Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.error)
            Text(message, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
fun MicStatus(state: MicState) {
    val device = state.selected?.let { "${it.type}:${it.name}" }
    val dbfs = if (state.dbfs.isFinite()) "${state.dbfs.roundToInt()} dBFS" else "−∞"
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        StatusIcon(
            icon = if (state.isRecording && device != null) Icons.Filled.Mic else Icons.Filled.MicOff,
            contentDescription = if (state.isRecording && device != null) "입력 측정 중" else "마이크 꺼짐",
            tint = if (state.isRecording && device != null) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (device != null) Text(device, Modifier.weight(1f)) else Spacer(Modifier.weight(1f))
        Text(dbfs)
    }
    LinearProgressIndicator(progress = { state.level }, modifier = Modifier.fillMaxWidth())
    ErrorText(state.error)
}
