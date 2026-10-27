package kr.modumoa.hdapp.contacts

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.auth.HandleRules
import kr.modumoa.hdapp.net.User
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun ContactsScreen(services: ServiceLocator, onRoom: (String) -> Unit) {
    var contacts by remember { mutableStateOf<List<User>>(emptyList()) }
    var handle by rememberSaveable { mutableStateOf("") }
    val room by services.rooms.state.collectAsStateWithLifecycle()
    val action = rememberActionState()
    LaunchedEffect(Unit) { action.run { contacts = services.apiClient.listContacts() } }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("친구", style = MaterialTheme.typography.headlineMedium)
                OutlinedTextField(handle, { handle = it }, Modifier.fillMaxWidth(), enabled = !action.busy,
                    label = { Text("친구 아이디") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
                Button(enabled = !action.busy, onClick = {
                    action.run {
                        require(HandleRules.isValid(handle.trim())) { HandleRules.HELP }
                        services.apiClient.addContact(handle.trim())
                        handle = ""
                        contacts = services.apiClient.listContacts()
                    }
                }) { Text("친구 추가") }
                TextButton(enabled = !action.busy, onClick = {
                    action.run { contacts = services.apiClient.listContacts() }
                }) { Text(if (action.busy) "처리 중…" else "목록 새로고침") }
                if (room.code != null) Text("현재 방에서 나가면 친구와 새 방을 만들 수 있습니다.")
                ErrorText(action.error)
            }
        }
        if (contacts.isEmpty() && !action.busy) item { Text("추가한 친구가 없습니다.") }
        items(contacts, key = { it.handle }) { contact ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${contact.displayName} (@${contact.handle})", style = MaterialTheme.typography.titleMedium)
                Button(enabled = !action.busy && room.code == null, onClick = {
                    action.run {
                        val created = services.apiClient.createRoom(invitees = listOf(contact.handle))
                        services.rooms.open(created.code)
                        onRoom(created.code)
                    }
                }) { Text("이 친구와 방 만들기") }
                OutlinedButton(enabled = !action.busy, onClick = {
                    action.run {
                        services.apiClient.removeContact(contact.handle)
                        contacts = services.apiClient.listContacts()
                    }
                }) { Text("친구 삭제") }
                HorizontalDivider()
            }
        }
    }
}
