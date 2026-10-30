package kr.modumoa.hdapp.audio

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kr.modumoa.hdapp.UnavoApplication
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class AudioChannel(private val activity: Activity, private val app: UnavoApplication, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "unavo/audio")
    private val events = EventChannel(messenger, "unavo/audio/levels")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var meterJob: Job? = null
    private var permissionResult: MethodChannel.Result? = null
    private var activityVisible = false

    init { methods.setMethodCallHandler(this); events.setStreamHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                when (call.method) {
                    "getState" -> result.success(app.micRouter.state.value.toMap())
                    "listInputs" -> result.success(app.micRouter.listInputs().map { it.toMap() })
                    "choose" -> {
                        app.micRouter.choose(call.argument<Int>("id"))
                        result.success(app.micRouter.state.value.toMap())
                    }
                    "startPreview" -> {
                        check(activityVisible) { "화면이 보이는 동안만 마이크 시험을 사용할 수 있습니다." }
                        app.micRouter.startPreview()
                        // 권한/장치 IO를 기다리는 사이 화면이 가려진 경우 시험을 되돌린다.
                        if (!activityVisible) app.micRouter.stopPreview()
                        result.success(null)
                    }
                    "stopPreview" -> { app.micRouter.stopPreview(); result.success(null) }
                    "permissions" -> result.success(permissions())
                    "requestPermissions" -> requestPermissions(result)
                    "openSettings" -> {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")))
                        result.success(null)
                    }
                    "setSpeakerphone" -> {
                        check(app.callState.value.isActive) { "통화에 참여한 뒤 출력을 변경해 주세요." }
                        result.success(app.setSpeakerphone(call.argument<Boolean>("enabled") == true))
                    }
                    else -> result.notImplemented()
                }
            } catch (cancelled: CancellationException) {
                result.error("cancelled", "요청이 중단되었습니다.", null)
                throw cancelled
            } catch (error: Exception) {
                result.error("audio_error", error.message ?: "마이크를 시작하지 못했습니다.", null)
            }
        }
    }

    // 기존 AudioPermissions.kt의 권한 조합을 Compose 없이 유지한다.
    private fun permissions(): Map<String, Boolean> = mapOf(
        "microphone" to (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED),
        "notifications" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED),
    )

    private fun requestPermissions(result: MethodChannel.Result) {
        if (permissionResult != null) { result.error("busy", "권한 요청을 확인해 주세요.", null); return }
        val required = mutableListOf<String>()
        val current = permissions()
        if (current["microphone"] != true) required += Manifest.permission.RECORD_AUDIO
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && current["notifications"] != true) required += Manifest.permission.POST_NOTIFICATIONS
        if (required.isEmpty()) { result.success(current); return }
        permissionResult = result
        try { activity.requestPermissions(required.toTypedArray(), PERMISSION_REQUEST) }
        catch (error: Exception) { permissionResult = null; throw error }
    }

    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        permissionResult?.success(permissions())
        permissionResult = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        meterJob?.cancel()
        // MicRouter는 1600 samples @16 kHz로 100ms마다 RMS/dBFS를 게시한다.
        meterJob = scope.launch { app.micRouter.state.collect { sink.success(it.toMap()) } }
    }
    override fun onCancel(arguments: Any?) { meterJob?.cancel(); meterJob = null }

    fun onActivityVisible() { activityVisible = true }
    fun stopPreviewWhenHidden() {
        activityVisible = false
        app.scope.launch { app.micRouter.stopPreview() }
    }
    fun dispose() {
        permissionResult?.error("cancelled", "요청이 중단되었습니다.", null)
        permissionResult = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        scope.cancel()
        stopPreviewWhenHidden()
    }

    private companion object { const val PERMISSION_REQUEST = 6201 }
}

private fun MicDevice.toMap(): Map<String, Any> = mapOf("id" to id, "type" to type, "name" to name)
private fun MicState.toMap(): Map<String, Any?> = mapOf(
    "mode" to if (mode == MicMode.CAR) "car" else "phone",
    "devices" to devices.map { it.toMap() }, "selected" to selected?.toMap(), "manualId" to manualId,
    "level" to level.toDouble(), "rms" to rms, "dbfs" to dbfs,
    "isRecording" to isRecording, "isPreviewing" to isPreviewing, "error" to error,
)
