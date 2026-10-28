package kr.modumoa.hdapp.audio

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.MotionDismiss
import kr.modumoa.hdapp.ui.MotionReveal
import kr.modumoa.hdapp.ui.StatusIcon

data class AudioPermissions(val microphone: Boolean, val notifications: Boolean, val request: () -> Unit)

@Composable
fun rememberAudioPermissions(): AudioPermissions {
    val context = LocalContext.current
    fun hasMicrophone() = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    fun hasNotifications() = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    var microphone by remember { mutableStateOf(hasMicrophone()) }
    var notifications by remember { mutableStateOf(hasNotifications()) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        microphone = hasMicrophone()
        notifications = hasNotifications()
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        microphone = hasMicrophone()
        notifications = hasNotifications()
    }
    return AudioPermissions(microphone, notifications) {
        val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) permissions += Manifest.permission.POST_NOTIFICATIONS
        launcher.launch(permissions.toTypedArray())
    }
}

@Composable
fun AudioPermissionControls(permissions: AudioPermissions) {
    val context = LocalContext.current
    AnimatedVisibility(visible = !permissions.microphone || !permissions.notifications,
        enter = MotionReveal, exit = MotionDismiss) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            if (!permissions.microphone) StatusIcon(Icons.Filled.MicOff, "마이크 권한 필요", MaterialTheme.colorScheme.error)
            if (!permissions.notifications) StatusIcon(Icons.Filled.NotificationsOff, "알림 권한 필요", MaterialTheme.colorScheme.error)
            Spacer(Modifier.weight(1f))
            CarIconButton(Icons.Filled.Key, "마이크·알림 권한 요청", onClick = permissions.request, style = CarButtonStyle.Filled)
            CarIconButton(Icons.Filled.Settings, "앱 권한 설정 열기", onClick = {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
            })
        }
    }
}
