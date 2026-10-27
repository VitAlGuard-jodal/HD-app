package kr.modumoa.hdapp.auth

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.net.ServerAddress
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.ScreenColumn
import kr.modumoa.hdapp.ui.rememberActionState

@Composable
fun AuthScreen(services: ServiceLocator) {
    var signup by rememberSaveable { mutableStateOf(false) }
    var handle by rememberSaveable { mutableStateOf("") }
    // 비밀번호는 저장 가능한 UI 상태나 SharedPreferences에 넣지 않는다.
    var password by remember { mutableStateOf("") }
    var displayName by rememberSaveable { mutableStateOf("") }
    var baseUrl by rememberSaveable { mutableStateOf(services.sessionStore.baseUrl) }
    val action = rememberActionState()

    ScreenColumn(Modifier.verticalScroll(rememberScrollState())) {
        Text("모두모아", style = MaterialTheme.typography.headlineMedium)
        TabRow(selectedTabIndex = if (signup) 1 else 0) {
            Tab(selected = !signup, onClick = { signup = false }, enabled = !action.busy, text = { Text("로그인") })
            Tab(selected = signup, onClick = { signup = true }, enabled = !action.busy, text = { Text("회원가입") })
        }
        OutlinedTextField(handle, { handle = it }, Modifier.fillMaxWidth(), enabled = !action.busy,
            label = { Text("아이디") }, supportingText = { Text(HandleRules.HELP) }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), enabled = !action.busy,
            label = { Text("비밀번호") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
            supportingText = { if (signup) Text("8~72자") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        if (signup) OutlinedTextField(displayName, { displayName = it }, Modifier.fillMaxWidth(),
            enabled = !action.busy, label = { Text("표시 이름 (2~20자)") }, singleLine = true)
        OutlinedTextField(baseUrl, { baseUrl = it }, Modifier.fillMaxWidth(), enabled = !action.busy,
            label = { Text("서버 base URL") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
        ErrorText(action.error)
        Button(enabled = !action.busy, onClick = {
            action.run {
                val id = handle.trim()
                require(HandleRules.isValid(id)) { HandleRules.HELP }
                require(password.isNotEmpty()) { "비밀번호를 입력해 주세요." }
                val name = displayName.trim()
                if (signup) {
                    require(name.codePointCount(0, name.length) in 2..20) { "표시 이름은 2~20자로 입력해 주세요." }
                    require(password.codePointCount(0, password.length) in 8..72) { "비밀번호는 8~72자로 입력해 주세요." }
                }
                services.sessionStore.baseUrl = ServerAddress.normalize(baseUrl)
                val result = if (signup) services.apiClient.signup(id, password, name)
                    else services.apiClient.login(id, password)
                password = ""
                services.sessionStore.save(result)
            }
        }) { Text(if (action.busy) "처리 중…" else if (signup) "회원가입" else "로그인") }
    }
}
