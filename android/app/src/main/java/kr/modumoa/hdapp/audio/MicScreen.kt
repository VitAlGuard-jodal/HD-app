package kr.modumoa.hdapp.audio

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kr.modumoa.hdapp.ui.MicStatus

@Composable
fun MicScreen(router: MicRouter) {
    val state by router.state.collectAsStateWithLifecycle()
    val permissions = rememberAudioPermissions()
    val eligible = MicRanker.rank(state.mode, state.devices).map { it.id }.toSet()
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("마이크", style = MaterialTheme.typography.headlineMedium)
                Text("모드: ${if (state.mode == MicMode.CAR) "차량" else "폰"}")
                AudioPermissionControls(permissions)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("자동 선택", Modifier.weight(1f))
                    Switch(checked = state.manualId == null, enabled = state.selected != null,
                        onCheckedChange = { automatic -> router.choose(if (automatic) null else state.selected?.id) })
                }
                MicStatus(state)
                Text("입력 장치", style = MaterialTheme.typography.titleMedium)
            }
        }
        if (state.devices.isEmpty()) item { Text("연결된 입력 장치가 없습니다.") }
        items(state.devices, key = { it.id }) { device ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = state.selected?.id == device.id, enabled = device.id in eligible,
                    onClick = { router.choose(device.id) })
                Column(Modifier.weight(1f)) {
                    Text(device.name)
                    Text("타입 ${device.type} · ID ${device.id}${if (device.id !in eligible) " · 통화 입력 제외" else ""}")
                }
            }
        }
    }
}
