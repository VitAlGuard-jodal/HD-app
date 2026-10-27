package kr.modumoa.hdapp.room

import kr.modumoa.hdapp.call.CallState
import kr.modumoa.hdapp.call.MediaEngine
import kr.modumoa.hdapp.net.ApiClient
import kr.modumoa.hdapp.net.Member
import kr.modumoa.hdapp.net.Room
import kr.modumoa.hdapp.net.RoomEvent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class RoomState(
    val code: String? = null,
    val room: Room? = null,
    val members: List<Member> = emptyList(),
    val isConnected: Boolean = false,
    val isLeaving: Boolean = false,
    val error: String? = null,
)

// 화면과 서비스가 SSE를 중복 구독하지 않도록 현재 방 하나를 공유한다.
class RoomSession(
    private val api: ApiClient,
    private val mediaEngine: MediaEngine,
    private val scope: CoroutineScope,
    private val callProvider: () -> CallState,
) {
    private val mutableState = MutableStateFlow(RoomState())
    val state: StateFlow<RoomState> = mutableState.asStateFlow()
    private var eventsJob: Job? = null

    fun open(code: String, force: Boolean = false) {
        if (state.value.isLeaving) return
        if (!force && state.value.code == code && eventsJob?.isActive == true) return
        eventsJob?.cancel()
        mutableState.value = if (state.value.code == code) state.value.copy(error = null, isConnected = false) else RoomState(code = code)
        eventsJob = scope.launch {
            refresh(code)
            try {
                api.subscribeEvents(code).collect { event ->
                    when (event) {
                        is RoomEvent.Signal -> mediaEngine.onSignal(event.from, event.kind, event.payload)
                        is RoomEvent.Disconnected -> mutableState.update {
                            it.copy(isConnected = false, error = "${event.message} (${event.retryInMillis / 1000}초 후)")
                        }
                        RoomEvent.Reconnected -> {
                            try {
                                api.joinRoom(code)
                                val call = callProvider()
                                if (call.isActive && call.roomCode == code) {
                                    call.selfHandle?.let { mediaEngine.join(code, it) }
                                }
                                refresh(code)
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (error: Exception) {
                                mutableState.update { it.copy(error = error.message ?: "방에 다시 참여하지 못했습니다.") }
                            }
                        }
                        is RoomEvent.Hello, is RoomEvent.MemberJoined, is RoomEvent.MemberLeft -> refresh(code)
                    }
                    if (event !is RoomEvent.Disconnected) mutableState.update { it.copy(isConnected = true) }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                mutableState.update { it.copy(isConnected = false, error = error.message ?: "방 연결을 확인해 주세요.") }
            }
        }
    }

    suspend fun leave() {
        val code = state.value.code ?: return
        if (state.value.isLeaving) return
        mutableState.update { it.copy(isConnected = false, isLeaving = true) }
        try {
            eventsJob?.cancelAndJoin()
            eventsJob = null
            api.leaveRoom(code)
            if (state.value.code == code) mutableState.value = RoomState()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            mutableState.update { it.copy(error = error.message ?: "방 나가기를 다시 시도해 주세요.") }
            throw error
        } finally {
            if (state.value.code == code) mutableState.update { it.copy(isLeaving = false) }
        }
    }

    fun forget() {
        eventsJob?.cancel()
        eventsJob = null
        mutableState.value = RoomState()
    }

    private suspend fun refresh(code: String) {
        try {
            val details = api.getRoom(code)
            if (state.value.code == code) mutableState.update {
                it.copy(room = details.room, members = details.members, error = null)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            if (state.value.code == code) mutableState.update { it.copy(error = error.message ?: "참여자를 불러오지 못했습니다.") }
        }
    }
}
