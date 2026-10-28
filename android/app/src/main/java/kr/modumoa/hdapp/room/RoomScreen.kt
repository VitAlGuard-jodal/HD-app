package kr.modumoa.hdapp.room

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SettingsVoice
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.audio.AudioPermissionButtons
import kr.modumoa.hdapp.audio.rememberAudioPermissions
import kr.modumoa.hdapp.call.CallForegroundService
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.IconPrimary
import kr.modumoa.hdapp.ui.IconTertiary
import kr.modumoa.hdapp.ui.LocalModumoaColors
import kr.modumoa.hdapp.ui.MicStatus
import kr.modumoa.hdapp.ui.MotionConnectionSpring
import kr.modumoa.hdapp.ui.MotionFast
import kr.modumoa.hdapp.ui.MotionItemFade
import kr.modumoa.hdapp.ui.MotionNormal
import kr.modumoa.hdapp.ui.StatusChip
import kr.modumoa.hdapp.ui.StatusIcon
import kr.modumoa.hdapp.ui.VehicleIcon
import kr.modumoa.hdapp.ui.WesternColumns
import kr.modumoa.hdapp.ui.WesternPanelTitle
import kr.modumoa.hdapp.ui.WesternScreen
import kr.modumoa.hdapp.ui.motionTween
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun RoomScreen(code: String, services: ServiceLocator, onLeft: () -> Unit, onMic: () -> Unit) {
    val context = LocalContext.current
    val room by services.rooms.state.collectAsStateWithLifecycle()
    val mic by services.micRouter.state.collectAsStateWithLifecycle()
    val call by services.callState.collectAsStateWithLifecycle()
    val permissions = rememberAudioPermissions()
    val needsAudioPermissions = !permissions.microphone || !permissions.notifications
    val action = rememberActionState()
    val colors = LocalModumoaColors.current
    val inCall = call.roomCode == code && (call.isStarting || call.isActive)
    LaunchedEffect(code) {
        if (services.rooms.state.value.code == code) services.rooms.open(code)
    }

    WesternScreen {
        WesternColumns(leftWeight = 640f / 1434f,
            rightContentPadding = PaddingValues(top = 9.dp, bottom = CarGap), header = {
            WesternPanelTitle(room.room?.name ?: "함께 가는 길") {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    AnimatedContent(targetState = room.isConnected,
                        transitionSpec = {
                            val enter = if (targetState) {
                                fadeIn(motionTween(MotionNormal)) + scaleIn(MotionConnectionSpring, initialScale = 0.6f)
                            } else fadeIn(motionTween(MotionFast))
                            (enter togetherWith fadeOut(motionTween(MotionFast))).using(null)
                        }, label = "참여자 목록 연결 상태") { connected ->
                        Box(Modifier.size(IconTertiary), contentAlignment = Alignment.Center) {
                            if (connected) StatusIcon(Icons.Filled.CheckCircle, "참여자 목록 연결됨", colors.onCall)
                            else CircularProgressIndicator(Modifier.size(IconTertiary).semantics {
                                contentDescription = "참여자 목록 연결 대기 중"
                            }, color = colors.onCall)
                        }
                    }
                    Text(if (inCall) "통화 중" else "통화 대기", style = MaterialTheme.typography.bodyMedium,
                        color = colors.onCall)
                }
            }
        }, left = {
            item {
                // 작은 창에서도 지정된 방 코드 서체·크기를 유지하고 가로로 확인할 수 있게 한다.
                Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                    Text(code, style = MaterialTheme.typography.displayLarge, softWrap = false)
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("연결된 차 ${room.members.size}대", style = MaterialTheme.typography.bodyLarge)
                    BoxWithConstraints(Modifier.fillMaxWidth()) {
                        val count = room.members.size.coerceIn(1, 3)
                        val chipWidth = ((maxWidth - CarGap * (count - 1)) / count).coerceAtLeast(220.dp)
                        LazyRow(Modifier.fillMaxWidth().height(CarTouchTarget), horizontalArrangement = Arrangement.spacedBy(CarGap)) {
                            items(room.members, key = { it.handle }) { member ->
                                Row(Modifier.width(chipWidth).heightIn(min = CarTouchTarget).animateItem(
                                    fadeInSpec = MotionItemFade, placementSpec = null, fadeOutSpec = MotionItemFade),
                                    horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                    val isSelf = member.handle == services.sessionStore.handle
                                    VehicleIcon(if (isSelf) "나" else null)
                                    Column(Modifier.weight(1f)) {
                                        Text(if (isSelf) "나" else member.displayName, style = MaterialTheme.typography.titleMedium,
                                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        Text("@${member.handle}", style = MaterialTheme.typography.bodyMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }, right = {
            item {
                FlowRow(Modifier.heightIn(min = CarTouchTarget + 32.dp),
                    horizontalArrangement = Arrangement.spacedBy(CarGap), verticalArrangement = Arrangement.spacedBy(CarGap)) {
                    if (needsAudioPermissions) {
                        AudioPermissionButtons(permissions, enabled = !action.busy && !room.isLeaving)
                    }
                    // 권한 상태가 바뀌어도 진행 중인 통화를 끊는 조작은 유지한다.
                    if (!needsAudioPermissions || inCall) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            CarIconButton(
                                icon = if (inCall) Icons.Filled.CallEnd else Icons.Filled.Call,
                                contentDescription = if (inCall) "통화 끊기" else "통화 참여",
                                containerColor = if (inCall) colors.destructive else colors.call,
                                contentColor = if (inCall) colors.onDestructive else colors.onCall,
                                animateContainerColor = true, iconSize = IconPrimary, style = CarButtonStyle.Filled,
                                enabled = !action.busy && !room.isLeaving && !call.isStopping &&
                                    (inCall || (!needsAudioPermissions && !call.isStarting && !call.isActive && room.code == code)),
                                onClick = {
                                    action.run {
                                        if (inCall) {
                                            CallForegroundService.stop(context)
                                        } else {
                                            val handle = services.sessionStore.handle ?: error("다시 로그인해 주세요.")
                                            CallForegroundService.join(context, code, handle)
                                        }
                                    }
                                })
                            // 시작 중에도 버튼 행 높이를 유지하도록 24dp 진행 표시 자리를 예약한다.
                            Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                                if (call.roomCode == code && call.isStarting) {
                                    CircularProgressIndicator(Modifier.size(24.dp).semantics {
                                        contentDescription = "마이크 시작 중"
                                    })
                                }
                            }
                        }
                    }
                    CarIconButton(Icons.Filled.SettingsVoice, "마이크 선택", onClick = onMic)
                    CarIconButton(Icons.AutoMirrored.Filled.ExitToApp, "방 나가기",
                        style = CarButtonStyle.Outlined, busy = room.isLeaving,
                        enabled = !action.busy && !room.isLeaving, onClick = {
                            action.run {
                                CallForegroundService.stop(context)
                                services.rooms.leave()
                                onLeft()
                            }
                        })
                }
            }
            item {
                // 80dp 상태 행과 열 끝 24dp 여백으로 칩과 재연결 버튼의 잘림을 막는다.
                FlowRow(Modifier.heightIn(min = CarTouchTarget),
                    horizontalArrangement = Arrangement.spacedBy(CarGap), verticalArrangement = Arrangement.spacedBy(CarGap)) {
                    MicStatus(mic, showLevel = false)
                    if (!room.isConnected && !room.isLeaving) {
                        CarIconButton(Icons.Filled.Refresh, "연결 다시 시도",
                            enabled = !action.busy && !room.isLeaving && room.code != null,
                            onClick = { services.rooms.open(code, force = true) })
                    }
                    StatusChip(Icons.AutoMirrored.Filled.VolumeOff, "음성 미전송")
                }
            }
            if (!action.error.isNullOrBlank() || !room.error.isNullOrBlank() ||
                !call.error.isNullOrBlank() || room.code == null) item {
                ErrorText(action.error)
                ErrorText(room.error)
                ErrorText(call.error)
                if (room.code == null) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        StatusIcon(Icons.Filled.Info, null)
                        Text("나간 방", style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        })
    }
}
