package kr.modumoa.hdapp

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import kr.modumoa.hdapp.audio.MicRouter
import kr.modumoa.hdapp.call.CallForegroundService
import kr.modumoa.hdapp.call.CallState
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// Activity/FlutterEngine 재생성 중에도 FGS와 오디오 경로의 소유자는 하나다.
class UnavoApplication : Application() {
    lateinit var micRouter: MicRouter
        private set
    private val manager by lazy { checkNotNull(getSystemService(AudioManager::class.java)) }
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val callState = MutableStateFlow(CallState())
    val callMuted = MutableStateFlow(false)
    val callActions = MutableSharedFlow<Map<String, Any?>>(extraBufferCapacity = 8)
    val outputState = MutableStateFlow<Map<String, Any?>>(emptyMap())
    var callSequence = 0
    var pendingOpenRoom: String? = null
    private var requestedOutput: String? = null // null: external, then speaker
    private var volumeWritable = true
    private var outputError: String? = null
    val isAutomotive get() = packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)

    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = devicesChanged()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = devicesChanged()
    }
    private val volumes = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            // Read AudioManager, not the untrusted broadcast's volume extras.
            if (intent?.action == VOLUME_CHANGED) publishOutput()
        }
    }

    override fun onCreate() {
        super.onCreate()
        // Set the process-wide gate before any FlutterEngine/getUserMedia.
        // manageAudioFocus=false alone still starts AudioSwitch and routes.
        AudioSwitchManager.setAudioSessionManagementEnabled(false)
        micRouter = MicRouter(this)
        manager.registerAudioDeviceCallback(devices, Handler(Looper.getMainLooper()))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            manager.addOnCommunicationDeviceChangedListener(mainExecutor) { publishOutput() }
        }
        ContextCompat.registerReceiver(this, volumes, IntentFilter(VOLUME_CHANGED), ContextCompat.RECEIVER_EXPORTED)
        scope.launch {
            // getOutputRoute reads only this field from MicState. Device and
            // volume changes have their own callbacks; meter ticks stay local.
            micRouter.state.distinctUntilChangedBy { it.isInterrupted }
                .collect { publishOutput() }
        }
        publishOutput()
    }

    fun requestStop() {
        val current = callState.value
        if (!current.isActive && !current.isStarting && !current.isStopping) return
        callState.update { it.copy(isActive = false, isStarting = false, isStopping = true) }
        if (!stopService(Intent(this, CallForegroundService::class.java))) {
            callSequence += 1
            callState.value = CallState(error = current.error)
        }
    }

    private fun routeName(device: AudioDeviceInfo?): String? = when (device?.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> "headphones"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "receiver"
        AudioDeviceInfo.TYPE_BUS -> if (isAutomotive) "carAudio" else null
        else -> null
    }

    private fun communicationDevices(): List<AudioDeviceInfo> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) manager.availableCommunicationDevices
        else manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()

    fun availableOutputs(): List<String> {
        if (isAutomotive) return listOf("carAudio")
        val available = communicationDevices().mapNotNull(::routeName).toSet()
        // This order is also the Flutter accessibility/cycling contract.
        return listOf("bluetooth", "headphones", "speaker", "receiver").filter { it in available }
    }

    @Suppress("DEPRECATION")
    fun getOutputRoute(): Map<String, Any?> {
        val route = if (isAutomotive) "carAudio"
        else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) routeName(manager.communicationDevice)
        else when {
            manager.isBluetoothScoOn -> "bluetooth"
            manager.isSpeakerphoneOn -> "speaker"
            communicationDevices().any { routeName(it) == "headphones" } -> "headphones"
            else -> "receiver"
        }
        val max = manager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
        val volume = manager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
        return mapOf("route" to (route ?: "speaker"), "available" to availableOutputs(),
            "callVolume" to if (isAutomotive && max > 0) (volume * 100.0 / max).roundToInt() else null,
            "volumeWritable" to volumeWritable, "interrupted" to micRouter.state.value.isInterrupted,
            "error" to outputError)
    }

    fun publishOutput() { outputState.value = getOutputRoute() }

    private fun devicesChanged() {
        if (callState.value.isActive) {
            runCatching { applyOutput() }.onFailure { outputError = it.message }
        }
        publishOutput()
    }

    @Suppress("DEPRECATION")
    private fun applyOutput() {
        // Leave the automotive HAL's VOICE_COMMUNICATION bus untouched.
        if (isAutomotive) return
        val outputs = availableOutputs()
        val desired = requestedOutput?.takeIf { it in outputs }
            ?: outputs.firstOrNull().also { requestedOutput = null }
            ?: error("사용 가능한 출력 장치가 없습니다.")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val device = communicationDevices().first { routeName(it) == desired }
            if (manager.communicationDevice?.id != device.id) {
                check(manager.setCommunicationDevice(device)) { "출력 장치를 변경하지 못했습니다." }
            }
        } else {
            if (desired == "bluetooth") {
                manager.startBluetoothSco()
                manager.isBluetoothScoOn = true
            } else {
                manager.stopBluetoothSco()
                manager.isBluetoothScoOn = false
            }
            manager.isSpeakerphoneOn = desired == "speaker"
        }
    }

    fun setOutputRoute(route: String): Map<String, Any?> {
        require(route in availableOutputs()) { "선택한 출력 장치가 연결되어 있지 않습니다." }
        requestedOutput = route
        outputError = null
        applyOutput()
        publishOutput()
        return outputState.value
    }

    fun setSpeakerphone(enabled: Boolean): Boolean {
        requestedOutput = if (enabled) null else "receiver"
        outputError = null
        applyOutput()
        publishOutput()
        return outputState.value["route"] == "speaker"
    }

    fun setCallVolume(percent: Int): Map<String, Any?> {
        check(isAutomotive) { "차량에서만 시스템 통화 음량을 조절할 수 있습니다." }
        try {
            val max = manager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
            val min = manager.getStreamMinVolume(AudioManager.STREAM_VOICE_CALL)
            val index = (percent.coerceIn(0, 100) * max / 100.0).roundToInt().coerceIn(min, max)
            manager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, index, 0)
            volumeWritable = true
            outputError = null
        } catch (_: SecurityException) {
            volumeWritable = false
            outputError = "차량 시스템 음량 권한이 없어 앱 통화 음량만 변경합니다."
        }
        publishOutput()
        return outputState.value
    }

    @Suppress("DEPRECATION")
    fun resetSpeakerphone() {
        requestedOutput = null
        callMuted.value = false
        if (!isAutomotive) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) manager.clearCommunicationDevice()
            else { manager.stopBluetoothSco(); manager.isBluetoothScoOn = false; manager.isSpeakerphoneOn = false }
        }
        publishOutput()
    }

    private companion object { const val VOLUME_CHANGED = "android.media.VOLUME_CHANGED_ACTION" }
}
