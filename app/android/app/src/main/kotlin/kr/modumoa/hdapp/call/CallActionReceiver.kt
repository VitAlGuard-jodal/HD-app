package kr.modumoa.hdapp.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kr.modumoa.hdapp.UnavoApplication

// 명시적·비공개 브로드캐스트. 알림은 통화만 끊고 방 멤버십은 유지한다.
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != CallForegroundService.ACTION_LEAVE) return
        val app = context.applicationContext as UnavoApplication
        app.callActions.tryEmit(mapOf("event" to "leaveCall"))
        // Dart 구독/Activity가 사라져도 녹음과 FGS를 반드시 종료한다.
        app.requestStop()
    }
}
