package kr.modumoa.hdapp.audio

import android.media.AudioDeviceInfo
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.EmptyListArtwork
import kr.modumoa.hdapp.ui.IconSecondary
import kr.modumoa.hdapp.ui.IconTertiary
import kr.modumoa.hdapp.ui.MicStatus
import kr.modumoa.hdapp.ui.ModumoaDeviceShape
import kr.modumoa.hdapp.ui.MotionItemFade
import kr.modumoa.hdapp.ui.StatusChip
import kr.modumoa.hdapp.ui.StatusIcon
import kr.modumoa.hdapp.ui.WesternColumns
import kr.modumoa.hdapp.ui.WesternPanelTitle
import kr.modumoa.hdapp.ui.WesternScreen
import kr.modumoa.hdapp.ui.modumoaFocusOutline
import kr.modumoa.hdapp.ui.modumoaIcon

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
    WesternScreen {
        WesternColumns(leftWeight = 600f / 1434f, header = {
            WesternPanelTitle("내 목소리가 닿도록") {
                StatusIcon(if (state.mode == MicMode.CAR) Icons.Filled.DirectionsCar else Icons.Filled.Smartphone,
                    if (state.mode == MicMode.CAR) "차량 모드" else "폰 모드")
                Text("마이크", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }, left = {
            if (state.devices.isEmpty()) item {
                EmptyListArtwork(Icons.Filled.MicOff, "연결된 입력 장치 없음")
            }
            items(state.devices, key = { it.id }) { device ->
                val selectedDevice = state.selected?.id == device.id
                val interactions = remember { MutableInteractionSource() }
                val focused by interactions.collectIsFocusedAsState()
                val deviceContent = if (selectedDevice) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
                Surface(
                    modifier = Modifier.fillMaxWidth().animateItem(
                        fadeInSpec = MotionItemFade, placementSpec = null, fadeOutSpec = MotionItemFade)
                        .modumoaFocusOutline(focused).semantics(mergeDescendants = true) {
                            contentDescription = "${device.type}:${device.name}"
                            role = Role.RadioButton
                            selected = selectedDevice
                        },
                    onClick = { router.choose(device.id) }, enabled = device.id in eligible,
                    interactionSource = interactions, shape = ModumoaDeviceShape,
                    color = MaterialTheme.colorScheme.surfaceContainerLow, contentColor = deviceContent,
                    border = BorderStroke(2.dp, if (selectedDevice) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline),
                ) {
                    Row(Modifier.fillMaxWidth().heightIn(min = CarTouchTarget).padding(horizontal = CarGap, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(CarGap), verticalAlignment = Alignment.CenterVertically) {
                        val deviceIcon = if (device.type == AudioDeviceInfo.TYPE_BUILTIN_MIC) {
                            if (state.mode == MicMode.CAR) Icons.Filled.DirectionsCar else Icons.Filled.Smartphone
                        } else iconFor(device.type)
                        Icon(modumoaIcon(deviceIcon), null, Modifier.size(IconSecondary), tint = deviceContent)
                        Text(device.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                        if (selectedDevice) Icon(modumoaIcon(Icons.Filled.Check), null, Modifier.size(IconTertiary), tint = deviceContent)
                        if (device.id !in eligible) Icon(Icons.Filled.Block, "통화 입력 제외", Modifier.size(IconTertiary), tint = deviceContent)
                    }
                }
            }
        }, right = {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MicStatus(state, leading = {
                        StatusChip(if (permissions.microphone) Icons.Filled.Check else Icons.Filled.MicOff,
                            if (permissions.microphone) "권한 허용됨" else "마이크 권한 필요")
                    })
                    val automaticInteractions = remember { MutableInteractionSource() }
                    val automaticFocused by automaticInteractions.collectIsFocusedAsState()
                    FlowRow(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(CarGap),
                        verticalArrangement = Arrangement.spacedBy(CarGap)) {
                        Surface(Modifier.width(216.dp).modumoaFocusOutline(automaticFocused),
                            color = MaterialTheme.colorScheme.surfaceContainerLow, shape = MaterialTheme.shapes.small,
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) {
                            Row(Modifier.heightIn(min = CarTouchTarget).padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text("자동 선택", style = MaterialTheme.typography.bodyMedium)
                                Spacer(Modifier.weight(1f))
                                Switch(modifier = Modifier.size(CarTouchTarget).semantics(mergeDescendants = true) { contentDescription = "자동 선택" },
                                    checked = state.manualId == null, enabled = state.selected != null,
                                    interactionSource = automaticInteractions,
                                    colors = SwitchDefaults.colors(
                                        checkedThumbColor = MaterialTheme.colorScheme.onPrimary,
                                        checkedTrackColor = MaterialTheme.colorScheme.primary,
                                        checkedBorderColor = MaterialTheme.colorScheme.primary,
                                        uncheckedThumbColor = MaterialTheme.colorScheme.onSurface,
                                        uncheckedTrackColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                                        uncheckedBorderColor = MaterialTheme.colorScheme.outline),
                                    onCheckedChange = { automatic -> router.choose(if (automatic) null else state.selected?.id) })
                            }
                        }
                        if (!permissions.microphone || !permissions.notifications) {
                            AudioPermissionButtons(permissions)
                        }
                        CarIconButton(Icons.Filled.GraphicEq, "마이크 시험",
                            modifier = Modifier.semantics { selected = state.isPreviewing && !inCall },
                            style = if (state.isPreviewing && !inCall) CarButtonStyle.Filled else CarButtonStyle.Tonal,
                            busy = previewBusy,
                            enabled = !inCall && !previewBusy &&
                                (state.isPreviewing || (permissions.microphone && state.selected != null)),
                            onClick = {
                                val preview = !(state.isPreviewing && !inCall)
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
                        Text(if (state.isPreviewing && !inCall) "시험 켜짐" else "시험 꺼짐",
                            Modifier.align(Alignment.CenterVertically),
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        })
    }
}
