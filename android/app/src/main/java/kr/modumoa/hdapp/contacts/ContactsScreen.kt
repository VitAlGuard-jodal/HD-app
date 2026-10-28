package kr.modumoa.hdapp.contacts

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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddIcCall
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PersonOff
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.auth.HandleRules
import kr.modumoa.hdapp.net.User
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.IconTertiary
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun ContactsScreen(services: ServiceLocator, onRoom: (String) -> Unit) {
    var contacts by remember { mutableStateOf<List<User>>(emptyList()) }
    var handle by rememberSaveable { mutableStateOf("") }
    val room by services.rooms.state.collectAsStateWithLifecycle()
    val action = rememberActionState()
    LaunchedEffect(Unit) { action.run { contacts = services.apiClient.listContacts() } }

    LazyColumn(Modifier.fillMaxSize().padding(CarGap), verticalArrangement = Arrangement.spacedBy(CarGap)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(CarGap)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(handle, { handle = it }, Modifier.weight(1f).heightIn(min = CarTouchTarget), enabled = !action.busy,
                        placeholder = { Text("아이디") },
                        leadingIcon = { Icon(Icons.Filled.AlternateEmail, null, Modifier.size(IconTertiary)) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
                    CarIconButton(Icons.Filled.PersonAdd, "친구 추가", style = CarButtonStyle.Filled,
                        busy = action.busy, enabled = !action.busy, onClick = {
                            action.run {
                                require(HandleRules.isValid(handle.trim())) { HandleRules.HELP }
                                services.apiClient.addContact(handle.trim())
                                handle = ""
                                contacts = services.apiClient.listContacts()
                            }
                        })
                    CarIconButton(Icons.Filled.Refresh, "목록 새로고침", enabled = !action.busy, onClick = {
                        action.run { contacts = services.apiClient.listContacts() }
                    })
                }
                ErrorText(action.error)
            }
        }
        if (contacts.isEmpty() && !action.busy) item {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.PersonOff, "추가한 친구 없음", Modifier.size(64.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        items(contacts, key = { it.handle }) { contact ->
            Column(verticalArrangement = Arrangement.spacedBy(CarGap)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Person, null, Modifier.size(IconTertiary), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Column(Modifier.weight(1f)) {
                        Text(contact.displayName, style = MaterialTheme.typography.bodyLarge)
                        Text("@${contact.handle}", style = MaterialTheme.typography.bodySmall)
                    }
                    CarIconButton(Icons.Filled.AddIcCall, "이 친구와 방 만들기",
                        containerColor = Color(0xFF1B5E20), style = CarButtonStyle.Filled,
                        enabled = !action.busy && room.code == null, onClick = {
                            action.run {
                                val created = services.apiClient.createRoom(invitees = listOf(contact.handle))
                                services.rooms.open(created.code)
                                onRoom(created.code)
                            }
                        })
                    CarIconButton(Icons.Filled.Delete, "친구 삭제", containerColor = MaterialTheme.colorScheme.error,
                        enabled = !action.busy, onClick = {
                            action.run {
                                services.apiClient.removeContact(contact.handle)
                                contacts = services.apiClient.listContacts()
                            }
                        })
                }
                HorizontalDivider()
            }
        }
    }
}
