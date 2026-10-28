package kr.modumoa.hdapp.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Login
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kr.modumoa.hdapp.R
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.net.ServerAddress
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.IconPrimary
import kr.modumoa.hdapp.ui.IconSecondary
import kr.modumoa.hdapp.ui.IconTertiary
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
        Image(painterResource(R.drawable.ic_launcher_foreground), contentDescription = "모두모아",
            modifier = Modifier.size(96.dp).align(Alignment.CenterHorizontally))
        PrimaryTabRow(selectedTabIndex = if (signup) 1 else 0) {
            Tab(selected = !signup, onClick = { signup = false }, enabled = !action.busy,
                modifier = Modifier.height(CarTouchTarget),
                icon = { Icon(Icons.AutoMirrored.Filled.Login, "로그인", Modifier.size(IconSecondary)) })
            Tab(selected = signup, onClick = { signup = true }, enabled = !action.busy,
                modifier = Modifier.height(CarTouchTarget),
                icon = { Icon(Icons.Filled.PersonAdd, "회원가입", Modifier.size(IconSecondary)) })
        }
        OutlinedTextField(handle, { handle = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget), enabled = !action.busy,
            placeholder = { Text("아이디") },
            leadingIcon = { Icon(Icons.Filled.AlternateEmail, null, Modifier.size(IconTertiary)) },
            supportingText = if (handle.isNotEmpty() && !HandleRules.isValid(handle.trim())) {
                { Text(HandleRules.HELP) }
            } else null, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget), enabled = !action.busy,
            placeholder = { Text("비밀번호") },
            leadingIcon = { Icon(Icons.Filled.Lock, null, Modifier.size(IconTertiary)) },
            singleLine = true, visualTransformation = PasswordVisualTransformation(),
            supportingText = if (signup && password.isNotEmpty() && password.codePointCount(0, password.length) !in 8..72) {
                { Text("8~72자") }
            } else null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        if (signup) OutlinedTextField(displayName, { displayName = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget),
            enabled = !action.busy, placeholder = { Text("표시 이름") },
            leadingIcon = { Icon(Icons.Filled.Badge, null, Modifier.size(IconTertiary)) },
            supportingText = if (displayName.isNotEmpty() && displayName.trim().let { it.codePointCount(0, it.length) !in 2..20 }) {
                { Text("2~20자") }
            } else null, singleLine = true)
        OutlinedTextField(baseUrl, { baseUrl = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget), enabled = !action.busy,
            placeholder = { Text("http://…") },
            leadingIcon = { Icon(Icons.Filled.Dns, null, Modifier.size(IconTertiary)) }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
        ErrorText(action.error)
        Button(modifier = Modifier.fillMaxWidth().height(CarTouchTarget).semantics {
            contentDescription = if (signup) "회원가입" else "로그인"
        }, enabled = !action.busy, onClick = {
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
        }) {
            if (action.busy) {
                CircularProgressIndicator(Modifier.size(IconTertiary), color = LocalContentColor.current, strokeWidth = 2.dp)
            } else {
                Icon(if (signup) Icons.Filled.PersonAdd else Icons.AutoMirrored.Filled.Login,
                    contentDescription = null, modifier = Modifier.size(IconPrimary))
            }
        }
    }
}
