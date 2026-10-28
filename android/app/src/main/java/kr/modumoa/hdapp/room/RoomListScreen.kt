package kr.modumoa.hdapp.room

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Tag
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
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.CarTextField
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.JoinedRoomNotice
import kr.modumoa.hdapp.ui.JoinedRoomReason
import kr.modumoa.hdapp.ui.MotionDismiss
import kr.modumoa.hdapp.ui.MotionReveal
import kr.modumoa.hdapp.ui.VehicleIcon
import kr.modumoa.hdapp.ui.WesternColumns
import kr.modumoa.hdapp.ui.WesternPanelTitle
import kr.modumoa.hdapp.ui.WesternScreen
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun RoomListScreen(services: ServiceLocator, onRoom: (String) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    val current by services.rooms.state.collectAsStateWithLifecycle()
    val action = rememberActionState()
    var lastJoinedCode by remember { mutableStateOf(current.code.orEmpty()) }
    LaunchedEffect(current.code) { current.code?.let { lastJoinedCode = it } }
    WesternScreen {
        WesternColumns(leftWeight = 570f / 1434f, header = {
            WesternPanelTitle("함께 갈 길") {
                Text("방 목록", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }, left = {
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap),
                    verticalAlignment = Alignment.CenterVertically) {
                    CarTextField(name, { name = it }, "방 이름", Icons.Filled.Edit, Modifier.weight(1f),
                        enabled = !action.busy && current.code == null)
                    if (current.code != null) JoinedRoomNotice() else {
                        CarIconButton(Icons.Filled.Add, "방 만들기", style = CarButtonStyle.Filled,
                            busy = action.busy, enabled = !action.busy && current.code == null, onClick = {
                                action.run {
                                    val room = services.apiClient.createRoom(name.trim().takeIf { it.isNotEmpty() })
                                    services.rooms.open(room.code)
                                    onRoom(room.code)
                                }
                            })
                    }
                }
            }
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap),
                    verticalAlignment = Alignment.CenterVertically) {
                    CarTextField(code, { code = it }, "방 코드", Icons.Filled.Tag, Modifier.weight(1f),
                        enabled = !action.busy && current.code == null,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters,
                            keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
                    if (current.code != null) JoinedRoomNotice() else {
                        CarIconButton(Icons.AutoMirrored.Filled.ArrowForward, "코드로 참여", style = CarButtonStyle.Filled,
                            busy = action.busy, enabled = !action.busy && current.code == null, onClick = {
                                action.run {
                                    require(code.trim().isNotEmpty()) { "방 코드를 입력해 주세요." }
                                    val room = services.apiClient.joinRoom(code.trim())
                                    services.rooms.open(room.code)
                                    onRoom(room.code)
                                }
                            })
                    }
                }
            }
            if (current.code != null) item {
                Text(JoinedRoomReason, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            item { ErrorText(action.error) }
        }, right = {
            item {
                AnimatedVisibility(visible = current.code != null, enter = MotionReveal, exit = MotionDismiss) {
                    val joinedCode = current.code ?: lastJoinedCode
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap),
                        verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.width(2.dp).height(CarTouchTarget).background(MaterialTheme.colorScheme.primary))
                        VehicleIcon("참여 중인 방")
                        Column(Modifier.weight(1f)) {
                            Text(current.room?.name ?: "함께 가는 길", style = MaterialTheme.typography.bodyLarge)
                            Text("$joinedCode / ${current.members.size}대", style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        CarIconButton(Icons.AutoMirrored.Filled.ArrowForward, "현재 방으로", onClick = { onRoom(joinedCode) })
                    }
                }
            }
        })
    }
}
