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
    private var ownsCall = false

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
                if (services.callState.value.isStopping) {
                    stopWithForeground(startId)
                    return START_NOT_STICKY
                }
                val code = intent.getStringExtra(EXTRA_ROOM_CODE)
                val handle = intent.getStringExtra(EXTRA_HANDLE)
                if (code.isNullOrBlank() || handle.isNullOrBlank() || handle != services.sessionStore.handle) {
                    stopWithForeground(startId)
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
                    showForegroundNotification(notification(code))
                    ownsCall = true
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
                    stopWithForeground(startId)
                }
            }
            ACTION_LEAVE -> {
                // 알림은 통화만 끊는다. 방 멤버십과 SSE 구독은 그대로 유지한다.
                stopWithForeground(startId)
            }
            else -> stopWithForeground(startId)
        }
        // API 34에서는 보이는 화면에서만 마이크 FGS에 다시 참여한다.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        // 참여를 맡지 않은 서비스가 지연된 알림 요청 등으로 생성돼도 다른 캡처는 정리하지 않는다.
        if (ownsCall) {
            // SSE 재연결이 종료 중인 미디어 엔진을 다시 참여시키지 않도록 활성 상태부터 내린다.
            services.callState.update { it.copy(isStarting = false, isActive = false, isStopping = true) }
            services.mediaEngine.leave()
            services.scope.launch {
                // IO 정리가 끝날 때까지 종료 상태를 유지하여 새 캡처가 먼저 시작되지 않게 한다.
                joinJob?.join()
                services.micRouter.release()
                services.callState.value = CallState(error = services.callState.value.error)
            }
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun showForegroundNotification(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopWithForeground(startId: Int) {
        // 즉시 종료하는 요청도 먼저 전경에 등록해 시작 시간 제한을 해제한다.
        try {
            showForegroundNotification(notification(services.callState.value.roomCode, "통화 종료 중"))
        } catch (error: Exception) {
            // 권한 회수 등으로 전경 등록이 거부되어도 종료 처리는 끝낸다.
            Log.w("CallForegroundService", "종료 전 전경 서비스 등록에 실패했습니다.", error)
        } finally {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
        }
    }

    private fun notification(
        code: String?,
        status: String = "통화 중",
    ): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).putExtra(EXTRA_ROOM_CODE, code)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val leave = PendingIntent.getService(this, 1,
            Intent(this, CallForegroundService::class.java).setAction(ACTION_LEAVE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle(if (code.isNullOrBlank()) "모두모아 · $status" else "모두모아 · 방 $code · $status")
            .setContentText(null)
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_call_end), "통화 끊기", leave).build())
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
