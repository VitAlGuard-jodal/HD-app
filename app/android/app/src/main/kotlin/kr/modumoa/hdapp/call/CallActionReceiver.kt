package kr.modumoa.hdapp.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kr.modumoa.hdapp.UnavoApplication

// 명시적·비공개 브로드캐스트. 방 멤버십과 WebRTC는 Dart에서 함께 정리한다.
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as UnavoApplication
        val code = intent.getStringExtra(CallForegroundService.EXTRA_ROOM_CODE)
        if (code == null || code != app.callState.value.roomCode) return
        when (intent.action) {
            CallForegroundService.ACTION_MUTE -> app.callActions.tryEmit(mapOf("event" to "toggleMute"))
            CallForegroundService.ACTION_LEAVE -> {
                app.callActions.tryEmit(mapOf("event" to "leaveCall"))
                // Also stop native audio if the Flutter engine has been destroyed.
                app.requestStop()
            }
        }
    }
}
