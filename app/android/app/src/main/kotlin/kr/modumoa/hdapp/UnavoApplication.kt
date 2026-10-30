package kr.modumoa.hdapp

import android.app.Application
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import kr.modumoa.hdapp.audio.MicRouter
import kr.modumoa.hdapp.call.CallForegroundService
import kr.modumoa.hdapp.call.CallState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

// Activity/FlutterEngine 재생성 중에도 FGS와 입력 캡처의 소유자는 하나다.
class UnavoApplication : Application() {
    lateinit var micRouter: MicRouter
        private set
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val callState = MutableStateFlow(CallState())
    val callActions = MutableSharedFlow<Map<String, Any?>>(extraBufferCapacity = 8)
    var callSequence = 0
    var pendingOpenRoom: String? = null

    override fun onCreate() {
        super.onCreate()
        micRouter = MicRouter(this)
    }

    fun requestStop() {
        val current = callState.value
        if (!current.isActive && !current.isStarting && !current.isStopping) return
        callState.update { it.copy(isActive = false, isStarting = false, isStopping = true) }
        // FGS의 onDestroy가 IO 정리를 마친 뒤 idle 상태를 게시한다.
        if (!stopService(Intent(this, CallForegroundService::class.java))) {
            callSequence += 1
            callState.value = CallState(error = current.error)
        }
    }

    @Suppress("DEPRECATION")
    fun setSpeakerphone(enabled: Boolean): Boolean {
        val manager = checkNotNull(getSystemService(AudioManager::class.java))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (enabled) {
                val speaker = manager.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    ?: error("스피커 출력을 사용할 수 없습니다.")
                check(manager.setCommunicationDevice(speaker)) { "스피커 출력을 변경하지 못했습니다." }
            } else manager.clearCommunicationDevice()
            return manager.communicationDevice?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        }
        manager.isSpeakerphoneOn = enabled
        return manager.isSpeakerphoneOn
    }

    @Suppress("DEPRECATION")
    fun resetSpeakerphone() {
        val manager = checkNotNull(getSystemService(AudioManager::class.java))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) manager.clearCommunicationDevice()
        else manager.isSpeakerphoneOn = false
    }
}
