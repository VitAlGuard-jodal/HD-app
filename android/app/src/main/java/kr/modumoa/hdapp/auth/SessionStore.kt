package kr.modumoa.hdapp.auth

import android.content.Context
import kr.modumoa.hdapp.BuildConfig
import kr.modumoa.hdapp.net.AuthResult
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class Session(val token: String, val handle: String, val displayName: String)

class SessionStore(context: Context) {
    private val preferences = context.getSharedPreferences("session", Context.MODE_PRIVATE)
    private val mutableSession = MutableStateFlow(readSession())
    val session: StateFlow<Session?> = mutableSession.asStateFlow()

    val token: String? get() = session.value?.token
    val handle: String? get() = session.value?.handle
    val displayName: String? get() = session.value?.displayName

    var baseUrl: String
        get() = preferences.getString("baseUrl", BuildConfig.DEFAULT_BASE_URL)
            ?: BuildConfig.DEFAULT_BASE_URL
        set(value) {
            preferences.edit().putString("baseUrl", value.trim().trimEnd('/')).apply()
        }

    fun save(result: AuthResult) {
        preferences.edit()
            .putString("token", result.token)
            .putString("handle", result.user.handle)
            .putString("displayName", result.user.displayName)
            .apply()
        mutableSession.value = Session(result.token, result.user.handle, result.user.displayName)
    }

    fun clear() {
        // 서버 주소는 다음 로그인에서도 그대로 사용한다.
        preferences.edit().remove("token").remove("handle").remove("displayName").apply()
        mutableSession.value = null
    }

    private fun readSession(): Session? {
        val token = preferences.getString("token", null)?.takeIf { it.isNotBlank() } ?: return null
        val handle = preferences.getString("handle", null) ?: return null
        return Session(token, handle, preferences.getString("displayName", handle) ?: handle)
    }
}
