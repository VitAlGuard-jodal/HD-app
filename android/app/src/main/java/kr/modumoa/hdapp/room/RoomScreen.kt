package kr.modumoa.hdapp.room

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.audio.AudioPermissionControls
import kr.modumoa.hdapp.audio.rememberAudioPermissions
import kr.modumoa.hdapp.call.CallForegroundService
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.MicStatus
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun RoomScreen(code: String, services: ServiceLocator, onLeft: () -> Unit, onMic: () -> Unit) {
    val context = LocalContext.current
    val room by services.rooms.state.collectAsStateWithLifecycle()
    val mic by services.micRouter.state.collectAsStateWithLifecycle()
    val call by services.callState.collectAsStateWithLifecycle()
    val permissions = rememberAudioPermissions()
    val action = rememberActionState()
    val inCall = call.roomCode == code && (call.isStarting || call.isActive)
    LaunchedEffect(code) {
        if (services.rooms.state.value.code == code) services.rooms.open(code)
    }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("방 코드", style = MaterialTheme.typography.titleMedium)
                Text(code, style = MaterialTheme.typography.displaySmall)
                room.room?.name?.let { Text(it) }
                Text(if (room.isConnected) "참여자 목록 연결됨" else "참여자 목록 연결 대기 중")
                Text("현재는 마이크 입력만 확인할 수 있으며, 다른 참여자에게 음성은 전송되지 않습니다.")
                MicStatus(mic)
                AudioPermissionControls(permissions)
                TextButton(onClick = onMic) { Text("마이크 선택") }
                Button(enabled = !action.busy && !room.isLeaving && !call.isStopping &&
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
                    }) {
                    Text(if (call.roomCode == code && call.isStopping) "통화 종료 중…" else if (inCall) "통화 끊기" else "통화 참여")
                }
                if (call.roomCode == code && call.isStarting) Text("마이크 시작 중…")
                OutlinedButton(enabled = !action.busy && !room.isLeaving, onClick = {
                    action.run {
                        CallForegroundService.stop(context)
                        services.rooms.leave()
                        onLeft()
                    }
                }) { Text(if (room.isLeaving) "방 나가는 중…" else "방 나가기") }
                TextButton(enabled = !action.busy && !room.isLeaving && room.code != null, onClick = { services.rooms.open(code, force = true) }) {
                    Text("연결 다시 시도")
                }
                ErrorText(action.error)
                ErrorText(room.error)
                ErrorText(call.error)
                if (room.code == null) Text("방에서 나갔습니다. 방 목록으로 돌아가 주세요.")
                Text("참여자 ${room.members.size}명", style = MaterialTheme.typography.titleMedium)
            }
        }
        items(room.members, key = { it.handle }) { member ->
            Text("${member.displayName} (@${member.handle})${if (member.handle == services.sessionStore.handle) " · 나" else ""}")
        }
    }
}
