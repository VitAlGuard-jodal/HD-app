package kr.modumoa.hdapp.room

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.ScreenColumn
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun RoomListScreen(services: ServiceLocator, onRoom: (String) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    val current by services.rooms.state.collectAsStateWithLifecycle()
    val action = rememberActionState()
    ScreenColumn(Modifier.verticalScroll(rememberScrollState())) {
        Text("통화 방", style = MaterialTheme.typography.headlineMedium)
        current.code?.let { joinedCode ->
            Text("참여 중인 방: $joinedCode")
            Button(onClick = { onRoom(joinedCode) }) { Text("현재 방으로 돌아가기") }
            Text("새 방을 만들거나 다른 방에 참여하려면 현재 방에서 나가 주세요.")
        }
        OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), enabled = !action.busy && current.code == null,
            label = { Text("방 이름 (선택)") }, singleLine = true)
        Button(enabled = !action.busy && current.code == null, onClick = {
            action.run {
                val room = services.apiClient.createRoom(name.trim().takeIf { it.isNotEmpty() })
                services.rooms.open(room.code)
                onRoom(room.code)
            }
        }) { Text("방 만들기") }
        OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth(), enabled = !action.busy && current.code == null,
            label = { Text("방 코드") }, singleLine = true)
        Button(enabled = !action.busy && current.code == null, onClick = {
            action.run {
                require(code.trim().isNotEmpty()) { "방 코드를 입력해 주세요." }
                val room = services.apiClient.joinRoom(code.trim())
                services.rooms.open(room.code)
                onRoom(room.code)
            }
        }) { Text(if (action.busy) "처리 중…" else "코드로 참여") }
        ErrorText(action.error)
    }
}
