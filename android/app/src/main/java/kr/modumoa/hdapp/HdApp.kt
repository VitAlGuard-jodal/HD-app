package kr.modumoa.hdapp

import android.app.Application
import android.content.Context
import kr.modumoa.hdapp.audio.MicRouter
import kr.modumoa.hdapp.auth.SessionStore
import kr.modumoa.hdapp.call.CallState
import kr.modumoa.hdapp.call.MediaEngine
import kr.modumoa.hdapp.call.NoopMediaEngine
import kr.modumoa.hdapp.net.ApiClient
import kr.modumoa.hdapp.room.RoomSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow

class HdApp : Application() {
    lateinit var services: ServiceLocator
        private set

    override fun onCreate() {
        super.onCreate()
        services = ServiceLocator(this)
    }
}

class ServiceLocator(context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val sessionStore = SessionStore(context)
    val apiClient = ApiClient({ sessionStore.baseUrl }, { sessionStore.token })
    val micRouter = MicRouter(context)
    val mediaEngine: MediaEngine = NoopMediaEngine()
    val callState = MutableStateFlow(CallState())
    val rooms = RoomSession(apiClient, mediaEngine, scope) { callState.value }
}
