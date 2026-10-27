package kr.modumoa.hdapp.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.io.IOException
import kr.modumoa.hdapp.audio.MicState
import kr.modumoa.hdapp.net.ApiException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

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
    Column(modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
}

@Composable
fun ErrorText(message: String?) {
    if (!message.isNullOrBlank()) Text(message, color = MaterialTheme.colorScheme.error)
}

@Composable
fun MicStatus(state: MicState) {
    Text("마이크: ${state.selected?.name ?: "사용 가능한 장치 없음"}")
    Text(if (state.isRecording) "입력 측정 중 · RMS ${state.rms}" else "통화 참여 후 입력 레벨을 측정합니다.")
    LinearProgressIndicator(progress = { state.level }, modifier = Modifier.fillMaxWidth())
    ErrorText(state.error)
}
