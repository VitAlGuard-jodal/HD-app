package kr.modumoa.hdapp.audio

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material3.Icon
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.IconTertiary
import kr.modumoa.hdapp.ui.MicStatus
import kr.modumoa.hdapp.ui.StatusIcon
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
    LazyColumn(Modifier.fillMaxSize().padding(CarGap), verticalArrangement = Arrangement.spacedBy(CarGap)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(CarGap)) {
                StatusIcon(if (state.mode == MicMode.CAR) Icons.Filled.DirectionsCar else Icons.Filled.Smartphone,
                    if (state.mode == MicMode.CAR) "차량 모드" else "폰 모드")
                AudioPermissionControls(permissions)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    StatusIcon(Icons.Filled.Autorenew, "자동 선택")
                    Spacer(Modifier.weight(1f))
                    Switch(modifier = Modifier.size(CarTouchTarget).semantics(mergeDescendants = true) { contentDescription = "자동 선택" },
                        checked = state.manualId == null, enabled = state.selected != null,
                        onCheckedChange = { automatic -> router.choose(if (automatic) null else state.selected?.id) })
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    StatusIcon(Icons.Filled.GraphicEq, "마이크 시험")
                    Spacer(Modifier.weight(1f))
                    Switch(modifier = Modifier.size(CarTouchTarget).semantics(mergeDescendants = true) { contentDescription = "마이크 시험" },
                        checked = state.isPreviewing && !inCall,
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
                MicStatus(state)
                StatusIcon(Icons.Filled.Mic, "입력 장치")
            }
        }
        if (state.devices.isEmpty()) item {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.MicOff, "연결된 입력 장치 없음", Modifier.size(64.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        items(state.devices, key = { it.id }) { device ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                RadioButton(modifier = Modifier.size(CarTouchTarget).semantics { contentDescription = "${device.type}:${device.name}" },
                    selected = state.selected?.id == device.id, enabled = device.id in eligible,
                    onClick = { router.choose(device.id) })
                Icon(iconFor(device.type), contentDescription = null, modifier = Modifier.size(IconTertiary), // 장식: 옆 장치 이름과 선택 항목 설명이 뜻을 전달
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("${device.type}:${device.name}", Modifier.weight(1f))
                if (device.id !in eligible) {
                    Icon(Icons.Filled.Block, "통화 입력 제외", Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
