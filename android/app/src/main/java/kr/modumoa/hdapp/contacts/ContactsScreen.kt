package kr.modumoa.hdapp.contacts

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddIcCall
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.PersonOff
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.auth.HandleRules
import kr.modumoa.hdapp.net.User
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.CarTextField
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.EmptyListArtwork
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.JoinedRoomNotice
import kr.modumoa.hdapp.ui.LocalModumoaColors
import kr.modumoa.hdapp.ui.MotionItemFade
import kr.modumoa.hdapp.ui.Rye
import kr.modumoa.hdapp.ui.WesternColumns
import kr.modumoa.hdapp.ui.WesternPanelTitle
import kr.modumoa.hdapp.ui.WesternScreen
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun ContactsScreen(services: ServiceLocator, onRoom: (String) -> Unit) {
    var contacts by remember { mutableStateOf<List<User>>(emptyList()) }
    var handle by rememberSaveable { mutableStateOf("") }
    val room by services.rooms.state.collectAsStateWithLifecycle()
    val action = rememberActionState()
    val colors = LocalModumoaColors.current
    LaunchedEffect(Unit) { action.run { contacts = services.apiClient.listContacts() } }

    WesternScreen {
        WesternColumns(leftWeight = 470f / 1434f, header = {
            WesternPanelTitle("같이 가는 사람들") {
                Text("친구 ${contacts.size}명", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }, left = {
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap),
                    verticalAlignment = Alignment.CenterVertically) {
                    CarTextField(handle, { handle = it }, "친구 아이디", Icons.Filled.AlternateEmail,
                        Modifier.weight(1f), enabled = !action.busy,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
                    CarIconButton(Icons.Filled.Add, "친구 추가", style = CarButtonStyle.Filled,
                        busy = action.busy, enabled = !action.busy, onClick = {
                            action.run {
                                require(HandleRules.isValid(handle.trim())) { HandleRules.HELP }
                                services.apiClient.addContact(handle.trim())
                                handle = ""
                                contacts = services.apiClient.listContacts()
                            }
                        })
                }
            }
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("목소리가 닿으면,\n서로 다른 차도 하나의 대열.", Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    CarIconButton(Icons.Filled.Refresh, "목록 새로고침", enabled = !action.busy, onClick = {
                        action.run { contacts = services.apiClient.listContacts() }
                    })
                }
            }
            if (!action.error.isNullOrBlank()) item { ErrorText(action.error) }
        }, right = {
            if (contacts.isEmpty() && !action.busy) item {
                EmptyListArtwork(Icons.Outlined.PersonOff, "추가한 친구 없음")
            }
            itemsIndexed(contacts, key = { _, contact -> contact.handle }) { index, contact ->
                BoxWithConstraints(Modifier.fillMaxWidth().animateItem(
                    fadeInSpec = MotionItemFade, placementSpec = null, fadeOutSpec = MotionItemFade)) {
                    val identity: @Composable (Modifier) -> Unit = { modifier ->
                        Row(modifier, horizontalArrangement = Arrangement.spacedBy(CarGap),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text((index + 1).toString().padStart(2, '0'), Modifier.width(60.dp),
                                fontFamily = Rye, fontSize = 24.sp, color = colors.accent)
                            Column(Modifier.weight(1f)) {
                                Text(contact.displayName, style = MaterialTheme.typography.titleMedium)
                                Text("@${contact.handle}", style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    val controls: @Composable () -> Unit = {
                        Row(horizontalArrangement = Arrangement.spacedBy(CarGap)) {
                            if (room.code != null) JoinedRoomNotice() else {
                                CarIconButton(Icons.Filled.AddIcCall, "이 친구와 방 만들기",
                                    containerColor = colors.call, contentColor = colors.onCall, style = CarButtonStyle.Filled,
                                    enabled = !action.busy && room.code == null, onClick = {
                                        action.run {
                                            val created = services.apiClient.createRoom(invitees = listOf(contact.handle))
                                            services.rooms.open(created.code)
                                            onRoom(created.code)
                                        }
                                    })
                            }
                            CarIconButton(Icons.Filled.Delete, "친구 삭제",
                                containerColor = colors.destructive, contentColor = colors.onDestructive,
                                enabled = !action.busy, onClick = {
                                    action.run {
                                        services.apiClient.removeContact(contact.handle)
                                        contacts = services.apiClient.listContacts()
                                    }
                                })
                        }
                    }
                    if (maxWidth >= 520.dp) {
                        Row(Modifier.fillMaxWidth().heightIn(min = CarTouchTarget),
                            horizontalArrangement = Arrangement.spacedBy(CarGap), verticalAlignment = Alignment.CenterVertically) {
                            identity(Modifier.weight(1f))
                            controls()
                        }
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(CarGap)) {
                            identity(Modifier.fillMaxWidth())
                            controls()
                        }
                    }
                }
            }
        })
    }
}
