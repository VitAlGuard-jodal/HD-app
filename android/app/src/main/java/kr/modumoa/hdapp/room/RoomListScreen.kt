package kr.modumoa.hdapp.room

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Login
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.IconTertiary
import kr.modumoa.hdapp.ui.LocalModumoaColors
import kr.modumoa.hdapp.ui.MotionDismiss
import kr.modumoa.hdapp.ui.MotionReveal
import kr.modumoa.hdapp.ui.ScreenColumn
import kr.modumoa.hdapp.ui.StatusIcon
import kr.modumoa.hdapp.ui.modumoaTextFieldColors
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun RoomListScreen(services: ServiceLocator, onRoom: (String) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    val current by services.rooms.state.collectAsStateWithLifecycle()
    val action = rememberActionState()
    var lastJoinedCode by remember { mutableStateOf(current.code.orEmpty()) }
    LaunchedEffect(current.code) {
        current.code?.let { lastJoinedCode = it }
    }
    ScreenColumn(Modifier.verticalScroll(rememberScrollState())) {
        AnimatedVisibility(visible = current.code != null, enter = MotionReveal, exit = MotionDismiss) {
            val joinedCode = current.code ?: lastJoinedCode
            Card(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large,
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    StatusIcon(Icons.Filled.Call, "참여 중인 방", LocalModumoaColors.current.call)
                    Text(joinedCode, Modifier.weight(1f), style = MaterialTheme.typography.displayMedium)
                    CarIconButton(Icons.AutoMirrored.Filled.ArrowForward, "현재 방으로", onClick = { onRoom(joinedCode) })
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(name, { name = it }, Modifier.weight(1f).heightIn(min = 96.dp)
                .semantics(mergeDescendants = true) { contentDescription = "방 이름" },
                enabled = !action.busy && current.code == null, shape = MaterialTheme.shapes.medium,
                colors = modumoaTextFieldColors(), placeholder = { Text("방 이름") },
                leadingIcon = { Icon(Icons.Filled.Edit, null, Modifier.size(IconTertiary)) }, singleLine = true) // 장식: 입력창 설명이 뜻을 전달
            CarIconButton(Icons.Filled.Add, "방 만들기", style = CarButtonStyle.Filled,
                busy = action.busy, enabled = !action.busy && current.code == null, onClick = {
                    action.run {
                        val room = services.apiClient.createRoom(name.trim().takeIf { it.isNotEmpty() })
                        services.rooms.open(room.code)
                        onRoom(room.code)
                    }
                })
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(code, { code = it }, Modifier.weight(1f).heightIn(min = 96.dp)
                .semantics(mergeDescendants = true) { contentDescription = "방 코드" },
                enabled = !action.busy && current.code == null, shape = MaterialTheme.shapes.medium,
                colors = modumoaTextFieldColors(), placeholder = { Text("방 코드") },
                leadingIcon = { Icon(Icons.Filled.Tag, null, Modifier.size(IconTertiary)) }, singleLine = true, // 장식: 입력창 설명이 뜻을 전달
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters,
                    keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
            CarIconButton(Icons.AutoMirrored.Filled.Login, "코드로 참여", style = CarButtonStyle.Filled,
                busy = action.busy, enabled = !action.busy && current.code == null, onClick = {
                    action.run {
                        require(code.trim().isNotEmpty()) { "방 코드를 입력해 주세요." }
                        val room = services.apiClient.joinRoom(code.trim())
                        services.rooms.open(room.code)
                        onRoom(room.code)
                    }
                })
        }
        ErrorText(action.error)
    }
}
