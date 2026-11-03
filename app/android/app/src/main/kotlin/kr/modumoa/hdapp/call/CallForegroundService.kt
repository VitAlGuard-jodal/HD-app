package kr.modumoa.hdapp.call

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import kr.modumoa.hdapp.MainActivity
import kr.modumoa.hdapp.R
import kr.modumoa.hdapp.UnavoApplication
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// Compose판 서비스의 마이크·FGS 수명 정책을 보존한다.
// RoomSession/MediaEngine은 Dart 소유이며 CallChannel 상태/액션으로 연결한다.
class CallForegroundService : Service() {
    private lateinit var app: UnavoApplication
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var joinJob: Job? = null
    private var microphoneObserver: Job? = null
    private var notificationJob: Job? = null
    private var ownsCall = false
    private var sequence = -1

    override fun onCreate() {
        super.onCreate()
        app = application as UnavoApplication
        checkNotNull(getSystemService(NotificationManager::class.java)).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "통화", NotificationManager.IMPORTANCE_LOW),
        )
    }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_JOIN -> {
                val requestedSequence = intent.getIntExtra(EXTRA_SEQUENCE, -1)
                if (requestedSequence != app.callSequence) {
                    if (!ownsCall && !app.callState.value.isStarting) stopWithForeground(startId)
                    return START_NOT_STICKY
                }
                if (app.callState.value.isStopping || !app.callState.value.isStarting) {
                    if (!ownsCall) stopWithForeground(startId)
                    return START_NOT_STICKY
                }
                val code = intent.getStringExtra(EXTRA_ROOM_CODE)
                val handle = intent.getStringExtra(EXTRA_HANDLE)
                if (code.isNullOrBlank() || handle.isNullOrBlank()) {
                    app.callState.value = CallState(error = "방 코드와 아이디를 확인해 주세요.")
                    stopWithForeground(startId)
                    return START_NOT_STICKY
                }
                if (ownsCall && sequence == requestedSequence) return START_NOT_STICKY
                try {
                    check(ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
                        PackageManager.PERMISSION_GRANTED) { "마이크 권한을 먼저 허용해 주세요." }
                    showForegroundNotification(notification(code))
                    ownsCall = true
                    sequence = requestedSequence
                    joinJob?.cancel()
                    microphoneObserver?.cancel()
                    joinJob = scope.launch {
                        try {
                            val chosen = app.micRouter.state.value.selected ?: app.micRouter.choose(null)
                                ?: error("사용 가능한 마이크가 없습니다.")
                            app.micRouter.apply(chosen)
                            if (app.callState.value.isStopping || sequence != app.callSequence) return@launch
                            app.callState.value = CallState(roomCode = code, selfHandle = handle, isActive = true)
                            app.setSpeakerphone(true)
                            notificationJob?.cancel()
                            notificationJob = scope.launch {
                                app.callMuted.collect {
                                    checkNotNull(getSystemService(NotificationManager::class.java))
                                        .notify(NOTIFICATION_ID, notification(code))
                                }
                            }
                            microphoneObserver = scope.launch {
                                app.micRouter.state.collect { mic ->
                                    if (!mic.isRecording && mic.error != null) {
                                        app.callState.update { it.copy(error = mic.error) }
                                        // Keep the already-started FGS available for reconnect.
                                        app.publishOutput()
                                    }
                                }
                            }
                        } catch (cancelled: CancellationException) { throw cancelled }
                        catch (error: Exception) {
                            app.callState.update { it.copy(error = error.message ?: "통화 참여에 실패했습니다.") }
                            stopSelf()
                        }
                    }
                } catch (error: Exception) {
                    app.callState.value = CallState(error = error.message ?: "통화 서비스를 시작하지 못했습니다.")
                    stopWithForeground(startId)
                }
            }
            ACTION_LEAVE -> stopWithForeground(startId)
            else -> stopWithForeground(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        if (ownsCall) {
            app.callState.update { it.copy(isStarting = false, isActive = false, isStopping = true) }
            app.scope.launch {
                joinJob?.join()
                app.micRouter.release()
                runCatching { app.resetSpeakerphone() }
                app.callState.value = CallState(error = app.callState.value.error)
            }
        } else if (app.callState.value.isStopping) {
            app.callState.value = CallState(error = app.callState.value.error)
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun showForegroundNotification(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        else startForeground(NOTIFICATION_ID, notification)
    }
    private fun stopWithForeground(startId: Int) {
        try { showForegroundNotification(notification(app.callState.value.roomCode, "통화 종료 중")) }
        catch (error: Exception) { Log.w("CallForegroundService", "종료 전 전경 서비스 등록에 실패했습니다.", error) }
        finally { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(startId) }
    }
    private fun notification(code: String?, status: String = "통화 중"): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .putExtra(EXTRA_ROOM_CODE, code).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val leave = PendingIntent.getBroadcast(this, 1, Intent(this, CallActionReceiver::class.java).setAction(ACTION_LEAVE).putExtra(EXTRA_ROOM_CODE, code),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val mute = PendingIntent.getBroadcast(this, 2, Intent(this, CallActionReceiver::class.java).setAction(ACTION_MUTE).putExtra(EXTRA_ROOM_CODE, code),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_small)
            .setContentTitle(if (code.isNullOrBlank()) "우나보 · $status" else "우나보 · 방 $code · $status")
            .setContentText(null).setContentIntent(open).setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_notification_small),
                if (app.callMuted.value) "음소거 해제" else "음소거", mute).build())
            .addAction(Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_call_end), "방 나가기", leave).build())
            .build()
    }
    companion object {
        const val ACTION_JOIN = "kr.modumoa.hdapp.action.JOIN"
        const val ACTION_MUTE = "kr.modumoa.hdapp.action.MUTE"
        const val ACTION_LEAVE = "kr.modumoa.hdapp.action.LEAVE"
        const val EXTRA_ROOM_CODE = "roomCode"
        const val EXTRA_HANDLE = "handle"
        const val EXTRA_SEQUENCE = "sequence"
        private const val CHANNEL_ID = "call"
        private const val NOTIFICATION_ID = 1
        fun join(context: Context, roomCode: String, handle: String, sequence: Int) {
            ContextCompat.startForegroundService(context, Intent(context, CallForegroundService::class.java)
                .setAction(ACTION_JOIN).putExtra(EXTRA_ROOM_CODE, roomCode)
                .putExtra(EXTRA_HANDLE, handle).putExtra(EXTRA_SEQUENCE, sequence))
        }
    }
}
