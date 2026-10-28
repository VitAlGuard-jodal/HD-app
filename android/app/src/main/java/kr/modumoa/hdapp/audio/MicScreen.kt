package kr.modumoa.hdapp.audio

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.ui.MicStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

@Composable
fun MicScreen(services: ServiceLocator) {
    val router = services.micRouter
    val state by router.state.collectAsStateWithLifecycle()
    val call by services.callState.collectAsStateWithLifecycle()
    val permissions = rememberAudioPermissions()
    val previewScope = rememberCoroutineScope()
    var previewJob by remember { mutableStateOf<Job?>(null) }
    var previewBusy by remember { mutableStateOf(false) }
    val inCall = call.isStarting || call.isActive || call.isStopping
    val eligible = MicRanker.rank(state.mode, state.devices).map { it.id }.toSet()
    DisposableEffect(router) {
        onDispose {
            // 화면 코루틴은 함께 취소되므로 정리는 애플리케이션 범위에서 실행한다.
            previewJob?.cancel()
            services.scope.launch { router.stopPreview() }
        }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        // 아직 IO 시작을 기다리는 시험 요청도 취소하여 백그라운드 캡처를 막는다.
        previewJob?.cancel()
        previewBusy = false
        services.scope.launch { router.stopPreview() }
    }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("마이크", style = MaterialTheme.typography.headlineMedium)
                Text("모드: ${if (state.mode == MicMode.CAR) "차량" else "폰"}")
                AudioPermissionControls(permissions)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("자동 선택", Modifier.weight(1f))
                    Switch(checked = state.manualId == null, enabled = state.selected != null,
                        onCheckedChange = { automatic -> router.choose(if (automatic) null else state.selected?.id) })
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("마이크 시험", Modifier.weight(1f))
                    Switch(checked = state.isPreviewing && !inCall,
                        enabled = !inCall && !previewBusy &&
                            (state.isPreviewing || (permissions.microphone && state.selected != null)),
                        onCheckedChange = { preview ->
                            previewBusy = true
                            previewJob = previewScope.launch {
                                try {
                                    if (preview) router.startPreview() else router.stopPreview()
                                } catch (cancelled: CancellationException) {
                                    throw cancelled
                                } catch (_: Exception) {
                                    // 시작 오류는 MicRouter 상태를 통해 MicStatus에 표시한다.
                                } finally {
                                    previewBusy = false
                                }
                            }
                        })
                }
                if (inCall) Text("통화 중에는 통화 레벨을 표시합니다")
                MicStatus(state)
                Text("입력 장치", style = MaterialTheme.typography.titleMedium)
            }
        }
        if (state.devices.isEmpty()) item { Text("연결된 입력 장치가 없습니다.") }
        items(state.devices, key = { it.id }) { device ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = state.selected?.id == device.id, enabled = device.id in eligible,
                    onClick = { router.choose(device.id) })
                Column(Modifier.weight(1f)) {
                    Text("${device.type}:${device.name}")
                    if (device.id !in eligible) Text("통화 입력 제외")
                }
            }
        }
    }
}
