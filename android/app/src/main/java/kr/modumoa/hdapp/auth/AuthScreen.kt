package kr.modumoa.hdapp.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
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
import androidx.compose.ui.graphics.ColorFilter
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
        // 임시 로고이며 디자인 라운드에서 정식 아이콘으로 교체한다.
        Surface(
            modifier = Modifier.size(96.dp).align(Alignment.CenterHorizontally),
            shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer,
        ) {
            Image(painterResource(R.drawable.ic_launcher_foreground), contentDescription = "모두모아",
                modifier = Modifier.size(96.dp), colorFilter = ColorFilter.tint(MaterialTheme.colorScheme.primary))
        }
        PrimaryTabRow(selectedTabIndex = if (signup) 1 else 0) {
            Tab(selected = !signup, onClick = { signup = false }, enabled = !action.busy,
                modifier = Modifier.height(CarTouchTarget).semantics(mergeDescendants = true) { contentDescription = "로그인" },
                icon = { Icon(Icons.AutoMirrored.Filled.Login, null, Modifier.size(IconSecondary)) }) // 장식: 탭 설명이 뜻을 전달
            Tab(selected = signup, onClick = { signup = true }, enabled = !action.busy,
                modifier = Modifier.height(CarTouchTarget).semantics(mergeDescendants = true) { contentDescription = "회원가입" },
                icon = { Icon(Icons.Filled.PersonAdd, null, Modifier.size(IconSecondary)) }) // 장식: 탭 설명이 뜻을 전달
        }
        OutlinedTextField(handle, { handle = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget)
            .semantics(mergeDescendants = true) { contentDescription = "아이디" }, enabled = !action.busy,
            placeholder = { Text("아이디") },
            leadingIcon = { Icon(Icons.Filled.AlternateEmail, null, Modifier.size(IconTertiary)) }, // 장식: 입력창 설명이 뜻을 전달
            supportingText = if (handle.isNotEmpty() && !HandleRules.isValid(handle.trim())) {
                { Text(HandleRules.HELP) }
            } else null, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget)
            .semantics(mergeDescendants = true) { contentDescription = "비밀번호" }, enabled = !action.busy,
            placeholder = { Text("비밀번호") },
            leadingIcon = { Icon(Icons.Filled.Lock, null, Modifier.size(IconTertiary)) }, // 장식: 입력창 설명이 뜻을 전달
            singleLine = true, visualTransformation = PasswordVisualTransformation(),
            supportingText = if (signup && password.isNotEmpty() && password.codePointCount(0, password.length) !in 8..72) {
                { Text("8~72자") }
            } else null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        if (signup) OutlinedTextField(displayName, { displayName = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget)
            .semantics(mergeDescendants = true) { contentDescription = "표시 이름" },
            enabled = !action.busy, placeholder = { Text("표시 이름") },
            leadingIcon = { Icon(Icons.Filled.Badge, null, Modifier.size(IconTertiary)) }, // 장식: 입력창 설명이 뜻을 전달
            supportingText = if (displayName.isNotEmpty() && displayName.trim().let { it.codePointCount(0, it.length) !in 2..20 }) {
                { Text("2~20자") }
            } else null, singleLine = true)
        OutlinedTextField(baseUrl, { baseUrl = it }, Modifier.fillMaxWidth().heightIn(min = CarTouchTarget)
            .semantics(mergeDescendants = true) { contentDescription = "서버 주소" }, enabled = !action.busy,
            placeholder = { Text("서버 주소") },
            leadingIcon = { Icon(Icons.Filled.Dns, null, Modifier.size(IconTertiary)) }, singleLine = true, // 장식: 입력창 설명이 뜻을 전달
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
                    contentDescription = null, modifier = Modifier.size(IconPrimary)) // 장식: 버튼 설명이 뜻을 전달
            }
        }
    }
}
