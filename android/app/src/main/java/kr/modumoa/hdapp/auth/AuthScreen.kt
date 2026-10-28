package kr.modumoa.hdapp.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Login
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kr.modumoa.hdapp.ServiceLocator
import kr.modumoa.hdapp.net.ServerAddress
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.CarTextField
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.LocalWesternFrame
import kr.modumoa.hdapp.ui.LoginBranding
import kr.modumoa.hdapp.ui.WesternScreen
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
    val handleError = handle.isNotEmpty() && !HandleRules.isValid(handle.trim())
    val passwordError = signup && password.isNotEmpty() && password.codePointCount(0, password.length) !in 8..72
    val nameError = signup && displayName.isNotEmpty() &&
        displayName.trim().let { it.codePointCount(0, it.length) !in 2..20 }
    val message = action.error?.takeIf { it.isNotBlank() } ?: when {
        handleError -> HandleRules.HELP
        passwordError -> "비밀번호는 8~72자로 입력해 주세요."
        nameError -> "표시 이름은 2~20자로 입력해 주세요."
        else -> null
    }
    val submit: @Composable () -> Unit = {
        CarIconButton(Icons.AutoMirrored.Filled.ArrowForward, if (signup) "회원가입" else "로그인",
            style = CarButtonStyle.Filled, busy = action.busy, enabled = !action.busy, onClick = {
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
            })
    }
    val handleField: @Composable (Modifier) -> Unit = { modifier ->
        CarTextField(handle, { handle = it }, "아이디", Icons.Filled.AlternateEmail, modifier,
            enabled = !action.busy, isError = handleError,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false))
    }
    val passwordField: @Composable (Modifier) -> Unit = { modifier ->
        CarTextField(password, { password = it }, "비밀번호", Icons.Filled.Lock, modifier,
            enabled = !action.busy, isError = passwordError, visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
    }
    val nameField: @Composable (Modifier) -> Unit = { modifier ->
        CarTextField(displayName, { displayName = it }, "표시 이름", Icons.Filled.Badge, modifier,
            enabled = !action.busy, isError = nameError)
    }
    val serverField: @Composable (Modifier) -> Unit = { modifier ->
        CarTextField(baseUrl, { baseUrl = it }, "서버 주소", Icons.Filled.Dns, modifier,
            enabled = !action.busy,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
    }
    val modes: @Composable () -> Unit = {
        Row(horizontalArrangement = Arrangement.spacedBy(CarGap)) {
            CarIconButton(Icons.AutoMirrored.Filled.Login, "로그인 모드", enabled = !action.busy,
                modifier = Modifier.semantics { selected = !signup },
                style = if (!signup) CarButtonStyle.Filled else CarButtonStyle.Tonal,
                onClick = { signup = false })
            CarIconButton(Icons.Filled.PersonAdd, "회원가입 모드", enabled = !action.busy,
                modifier = Modifier.semantics { selected = signup },
                style = if (signup) CarButtonStyle.Filled else CarButtonStyle.Tonal,
                onClick = { signup = true })
        }
    }

    WesternScreen {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val fixedLayout = maxWidth >= 900.dp && !LocalWesternFrame.current.compact // 키보드로 maxHeight 가 줄어도 배치를 바꾸지 않는다(포커스 유지)
            val title: @Composable (Modifier) -> Unit = { modifier ->
                Column(modifier) {
                    Text("목소리로, 같은 길 위에.", style = MaterialTheme.typography.headlineMedium,
                        maxLines = if (fixedLayout) 1 else Int.MAX_VALUE, overflow = TextOverflow.Ellipsis)
                    // 보조 문구 자리를 오류와 공유하므로 검증 결과가 입력 행 높이를 늘리지 않는다.
                    Text(message ?: "낯선 길도, 함께라면 우리의 길. 정차 중에 계정을 연결하세요.",
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (message != null) MaterialTheme.colorScheme.onError else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (fixedLayout) 1 else Int.MAX_VALUE, overflow = TextOverflow.Ellipsis)
                }
            }
            if (fixedLayout) {
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(CarGap)) {
                    Row(Modifier.fillMaxWidth().height(CarTouchTarget),
                        horizontalArrangement = Arrangement.spacedBy(CarGap), verticalAlignment = Alignment.CenterVertically) {
                        title(Modifier.weight(1f))
                        modes()
                    }
                    Row(Modifier.fillMaxWidth().height(CarTouchTarget), horizontalArrangement = Arrangement.spacedBy(CarGap)) {
                        handleField(Modifier.weight(1f))
                        passwordField(Modifier.weight(1f))
                        if (signup) nameField(Modifier.weight(1f))
                        submit()
                    }
                    // 24dp 행 간격에 16dp를 보태 엠블럼 위 보호 영역 40dp를 확보한다.
                    // 80 + 24 + 80 + 24 + 16 + 80 = 304dp, 아래에도 36 + 패널 여백 30dp가 남는다.
                    Row(Modifier.fillMaxWidth().padding(top = 16.dp).height(CarTouchTarget),
                        horizontalArrangement = Arrangement.spacedBy(CarGap), verticalAlignment = Alignment.CenterVertically) {
                        LoginBranding(Modifier.width(380.dp), verticalClearspace = 0.dp)
                        serverField(Modifier.weight(1f))
                    }
                }
            } else {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 9.dp),
                    verticalArrangement = Arrangement.spacedBy(CarGap)) {
                    item { title(Modifier.fillMaxWidth()) }
                    item { modes() }
                    item { handleField(Modifier.fillMaxWidth()) }
                    item { passwordField(Modifier.fillMaxWidth()) }
                    if (signup) item { nameField(Modifier.fillMaxWidth()) }
                    item { submit() }
                    item { serverField(Modifier.fillMaxWidth()) }
                    item { LoginBranding() }
                }
            }
        }
    }
}
