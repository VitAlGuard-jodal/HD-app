package kr.modumoa.hdapp.call

data class CallState(
    val roomCode: String? = null,
    val selfHandle: String? = null,
    val isStarting: Boolean = false,
    val isActive: Boolean = false,
    val error: String? = null,
)
