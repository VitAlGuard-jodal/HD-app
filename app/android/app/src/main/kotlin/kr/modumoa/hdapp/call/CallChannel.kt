package kr.modumoa.hdapp.call

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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

class CallChannel(private val app: UnavoApplication, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "unavo/call")
    private val events = EventChannel(messenger, "unavo/call/events")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var stateJob: Job? = null
    private var actionJob: Job? = null

    init { methods.setMethodCallHandler(this); events.setStreamHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                when (call.method) {
                    "getState" -> result.success(app.callState.value.toMap())
                    "start" -> {
                        val code = requireNotNull(call.argument<String>("roomCode"))
                        val handle = requireNotNull(call.argument<String>("handle"))
                        require(code.isNotBlank() && handle.isNotBlank()) { "방 코드와 아이디를 확인해 주세요." }
                        val current = app.callState.value
                        check(!current.isStopping) { "통화 종료 중입니다." }
                        check(current.roomCode == null || current.roomCode == code) { "현재 통화에서 나간 뒤 다른 방에 참여해 주세요." }
                        if (!current.isActive && !current.isStarting) {
                            app.callSequence += 1
                            app.callState.value = CallState(roomCode = code, selfHandle = handle, isStarting = true)
                            try { CallForegroundService.join(app, code, handle, app.callSequence) }
                            catch (error: Exception) {
                                app.callState.value = CallState(error = error.message ?: "통화 서비스를 시작하지 못했습니다.")
                                throw error
                            }
                        }
                        val active = withTimeout(20_000) { app.callState.first { !it.isStarting } }
                        check(active.isActive) { active.error ?: "통화 참여에 실패했습니다." }
                        result.success(active.toMap())
                    }
                    "setMuted" -> {
                        app.callMuted.value = call.argument<Boolean>("muted") == true
                        result.success(null)
                    }
                    "stop" -> {
                        app.requestStop()
                        withTimeout(20_000) { app.callState.first { !it.isActive && !it.isStarting && !it.isStopping } }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (cancelled: CancellationException) {
                if (call.method == "start") app.requestStop()
                result.error("cancelled", "요청이 중단되었습니다.", null)
                throw cancelled
            } catch (error: Exception) {
                result.error("call_error", error.message ?: "통화 서비스를 시작하지 못했습니다.", null)
            }
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        onCancel(null)
        stateJob = scope.launch { app.callState.collect { sink.success(it.toMap() + ("event" to "state")) } }
        actionJob = scope.launch { app.callActions.collect { sink.success(it) } }
        app.pendingOpenRoom?.let { sink.success(mapOf("event" to "openRoom", "roomCode" to it)); app.pendingOpenRoom = null }
    }
    override fun onCancel(arguments: Any?) { stateJob?.cancel(); actionJob?.cancel(); stateJob = null; actionJob = null }
    fun dispose() { methods.setMethodCallHandler(null); events.setStreamHandler(null); scope.cancel() }
}

private fun CallState.toMap(): Map<String, Any?> = mapOf(
    "roomCode" to roomCode, "selfHandle" to selfHandle, "isStarting" to isStarting,
    "isActive" to isActive, "isStopping" to isStopping, "error" to error,
)
