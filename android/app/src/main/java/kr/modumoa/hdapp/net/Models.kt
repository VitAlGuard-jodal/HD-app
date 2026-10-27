package kr.modumoa.hdapp.net

data class User(val handle: String, val displayName: String)
data class AuthResult(val user: User, val token: String)
data class Room(val code: String, val name: String?)
data class Member(val handle: String, val displayName: String, val joinedAt: String)
data class RoomDetails(val room: Room, val members: List<Member>)

class ApiException(val status: Int, val code: String, message: String) : Exception(message)

sealed interface RoomEvent {
    data class Hello(val self: String) : RoomEvent
    data class MemberJoined(val handle: String) : RoomEvent
    data class MemberLeft(val handle: String) : RoomEvent
    data class Signal(val from: String, val kind: String, val payload: Any?) : RoomEvent
    data object Reconnected : RoomEvent
    data class Disconnected(val message: String, val retryInMillis: Long) : RoomEvent
}
