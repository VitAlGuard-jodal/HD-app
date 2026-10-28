package kr.modumoa.hdapp.room

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SettingsVoice
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.R
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.audio.AudioPermissionControls
import kr.modumoa.hdapp.audio.rememberAudioPermissions
import kr.modumoa.hdapp.call.CallForegroundService
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.IconPrimary
import kr.modumoa.hdapp.ui.IconSecondary
import kr.modumoa.hdapp.ui.IconTertiary
import kr.modumoa.hdapp.ui.MicStatus
import kr.modumoa.hdapp.ui.LocalModumoaColors
import kr.modumoa.hdapp.ui.MotionConnectionSpring
import kr.modumoa.hdapp.ui.MotionFast
import kr.modumoa.hdapp.ui.MotionItemFade
import kr.modumoa.hdapp.ui.MotionItemPlacement
import kr.modumoa.hdapp.ui.MotionNormal
import kr.modumoa.hdapp.ui.StatusIcon
import kr.modumoa.hdapp.ui.motionTween
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun RoomScreen(code: String, services: ServiceLocator, onLeft: () -> Unit, onMic: () -> Unit) {
    val context = LocalContext.current
    val room by services.rooms.state.collectAsStateWithLifecycle()
    val mic by services.micRouter.state.collectAsStateWithLifecycle()
    val call by services.callState.collectAsStateWithLifecycle()
    val permissions = rememberAudioPermissions()
    val action = rememberActionState()
    val colors = LocalModumoaColors.current
    val inCall = call.roomCode == code && (call.isStarting || call.isActive)
    LaunchedEffect(code) {
        if (services.rooms.state.value.code == code) services.rooms.open(code)
    }

    LazyColumn(Modifier.fillMaxSize().padding(CarGap), verticalArrangement = Arrangement.spacedBy(CarGap)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(CarGap)) {
                // 정본 §8에 따라 방 코드·연결 상태·계기 뒤에는 선버스트를 배치하지 않는다.
                Text(code, style = MaterialTheme.typography.displayLarge)
                room.room?.name?.let { Text(it, style = MaterialTheme.typography.displaySmall) }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Surface(shape = MaterialTheme.shapes.small,
                        color = colors.callContainer, contentColor = colors.onCallContainer) {
                        AnimatedContent(targetState = room.isConnected,
                            modifier = Modifier.padding(12.dp),
                            transitionSpec = {
                                val enter = if (targetState) {
                                    fadeIn(motionTween(MotionNormal)) + scaleIn(MotionConnectionSpring, initialScale = 0.6f)
                                } else fadeIn(motionTween(MotionFast))
                                (enter togetherWith fadeOut(motionTween(MotionFast))).using(null)
                            }, label = "참여자 목록 연결 상태") { connected ->
                            if (connected) {
                                StatusIcon(Icons.Filled.CheckCircle, "참여자 목록 연결됨", colors.onCallContainer)
                            } else {
                                CircularProgressIndicator(Modifier.size(IconTertiary).semantics {
                                    contentDescription = "참여자 목록 연결 대기 중"
                                }, color = colors.onCallContainer)
                            }
                        }
                    }
                    if (!room.isConnected) {
                        CarIconButton(Icons.Filled.Refresh, "연결 다시 시도",
                            enabled = !action.busy && !room.isLeaving && room.code != null,
                            onClick = { services.rooms.open(code, force = true) })
                    }
                    Surface(
                        modifier = Modifier.heightIn(min = 48.dp).semantics(mergeDescendants = true) {
                            contentDescription = "음성 미전송"
                        },
                        shape = MaterialTheme.shapes.small, color = colors.warningContainer, contentColor = colors.warning,
                    ) {
                        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.AutoMirrored.Filled.VolumeOff, null, Modifier.size(IconTertiary)) // 장식: 부모 설명과 옆 글자가 뜻을 전달
                            Text("음성 미전송")
                        }
                    }
                }
                MicStatus(mic)
                AudioPermissionControls(permissions)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically) {
                    CarIconButton(Icons.Filled.SettingsVoice, "마이크 선택", onClick = onMic)
                    Column(horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CarIconButton(
                            icon = if (inCall) Icons.Filled.CallEnd else Icons.Filled.Call,
                            contentDescription = if (inCall) "통화 끊기" else "통화 참여",
                            containerColor = if (inCall) colors.destructive else colors.call,
                            contentColor = if (inCall) colors.onDestructive else colors.onCall,
                            animateContainerColor = true,
                            iconSize = IconPrimary, style = CarButtonStyle.Filled,
                            busy = (call.roomCode == code && call.isStopping),
                            enabled = !action.busy && !room.isLeaving && !call.isStopping &&
                                (inCall || (permissions.microphone && !call.isStarting && !call.isActive && room.code == code)),
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
                        // 진행 표시 자리를 항상 확보해 시작 중에도 행 높이가 바뀌지 않게 한다.
                        Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                            if (call.roomCode == code && call.isStarting) {
                                CircularProgressIndicator(Modifier.size(24.dp).semantics {
                                    contentDescription = "마이크 시작 중"
                                })
                            }
                        }
                    }
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
                ErrorText(action.error)
                ErrorText(room.error)
                ErrorText(call.error)
                if (room.code == null) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Info, null, Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.onSurfaceVariant) // 장식: 옆 글자가 뜻을 전달
                        Text("나간 방")
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    StatusIcon(Icons.Filled.Groups, "참여자")
                    Text("${room.members.size}", style = MaterialTheme.typography.titleMedium)
                    if (room.members.isEmpty()) {
                        Image(painterResource(R.drawable.brand_voice_bloom), contentDescription = null,
                            modifier = Modifier.size(32.dp))
                    }
                }
            }
        }
        items(room.members, key = { it.handle }) { member ->
            Surface(
                modifier = Modifier.fillMaxWidth().animateItem(
                    fadeInSpec = MotionItemFade, placementSpec = MotionItemPlacement, fadeOutSpec = MotionItemFade),
                shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow,
            ) {
                Row(Modifier.fillMaxWidth().heightIn(min = 128.dp).padding(CarGap), horizontalArrangement = Arrangement.spacedBy(CarGap),
                    verticalAlignment = Alignment.CenterVertically) {
                    val isSelf = member.handle == services.sessionStore.handle
                    Icon(if (isSelf) Icons.Filled.AccountCircle else Icons.Outlined.Person,
                        contentDescription = if (isSelf) "나" else null, modifier = Modifier.size(IconSecondary), // 장식: 다른 참여자는 옆 이름과 아이디가 뜻을 전달
                        tint = if (isSelf) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    Column(Modifier.weight(1f)) {
                        Text(member.displayName, style = MaterialTheme.typography.headlineSmall)
                        Text("@${member.handle}", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}
