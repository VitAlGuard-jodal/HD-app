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
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import kr.modumoa.hdapp.HdApp
import kr.modumoa.hdapp.MainActivity
import kr.modumoa.hdapp.R
import kr.modumoa.hdapp.ServiceLocator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class CallForegroundService : Service() {
    private lateinit var services: ServiceLocator
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var joinJob: Job? = null
    private var microphoneObserver: Job? = null

    override fun onCreate() {
        super.onCreate()
        services = (application as HdApp).services
        checkNotNull(getSystemService(NotificationManager::class.java)).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "통화", NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_JOIN -> {
                val code = intent.getStringExtra(EXTRA_ROOM_CODE)
                val handle = intent.getStringExtra(EXTRA_HANDLE)
                if (code.isNullOrBlank() || handle.isNullOrBlank() || handle != services.sessionStore.handle) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (services.callState.value.roomCode == code &&
                    (services.callState.value.isActive || services.callState.value.isStarting)) return START_NOT_STICKY
                if (services.callState.value.roomCode != null && services.callState.value.roomCode != code) {
                    services.callState.update { it.copy(error = "현재 통화에서 나간 뒤 다른 방에 참여해 주세요.") }
                    return START_NOT_STICKY
                }
                try {
                    check(ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
                        PackageManager.PERMISSION_GRANTED) { "마이크 권한을 먼저 허용해 주세요." }
                    val notification = notification(code)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    services.callState.value = CallState(roomCode = code, selfHandle = handle, isStarting = true)
                    joinJob?.cancel()
                    microphoneObserver?.cancel()
                    joinJob = scope.launch {
                        try {
                            services.rooms.open(code)
                            val chosen = services.micRouter.state.value.selected
                                ?: services.micRouter.choose(null)
                                ?: error("사용 가능한 마이크가 없습니다.")
                            services.micRouter.apply(chosen)
                            services.mediaEngine.join(code, handle)
                            services.callState.value = CallState(roomCode = code, selfHandle = handle, isActive = true)
                            microphoneObserver = scope.launch {
                                services.micRouter.state.collect { mic ->
                                    if (!mic.isRecording && mic.error != null) {
                                        services.callState.update { it.copy(error = mic.error) }
                                        stopSelf()
                                    }
                                }
                            }
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (error: Exception) {
                            services.callState.update { it.copy(error = error.message ?: "통화 참여에 실패했습니다.") }
                            stopSelf()
                        }
                    }
                } catch (error: Exception) {
                    services.callState.value = CallState(error = error.message ?: "통화 서비스를 시작하지 못했습니다.")
                    stopSelf()
                }
            }
            ACTION_LEAVE -> {
                // 알림에서 나가도 마이크는 즉시 종료하고 서버 멤버십을 정리한다.
                services.scope.launch {
                    try { services.rooms.leave() } catch (_: Exception) { /* 오류는 방 화면에 남는다. */ }
                }
                stopSelf()
            }
            else -> stopSelf()
        }
        // API 34에서는 보이는 화면에서만 마이크 FGS에 다시 참여한다.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        services.mediaEngine.leave()
        services.callState.value = CallState(error = services.callState.value.error)
        services.scope.launch { services.micRouter.release() }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun notification(code: String): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).putExtra(EXTRA_ROOM_CODE, code)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val leave = PendingIntent.getService(this, 1,
            Intent(this, CallForegroundService::class.java).setAction(ACTION_LEAVE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("모두모아 · 방 $code")
            .setContentText("마이크 사용 중 · 음성 전송은 아직 연결되지 않았습니다.")
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "나가기", leave).build())
            .build()
    }

    companion object {
        const val ACTION_JOIN = "kr.modumoa.hdapp.action.JOIN"
        const val ACTION_LEAVE = "kr.modumoa.hdapp.action.LEAVE"
        const val EXTRA_ROOM_CODE = "roomCode"
        const val EXTRA_HANDLE = "handle"
        private const val CHANNEL_ID = "call"
        private const val NOTIFICATION_ID = 1

        fun join(context: Context, roomCode: String, handle: String) {
            ContextCompat.startForegroundService(context, Intent(context, CallForegroundService::class.java)
                .setAction(ACTION_JOIN).putExtra(EXTRA_ROOM_CODE, roomCode).putExtra(EXTRA_HANDLE, handle))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallForegroundService::class.java))
        }
    }
}
