package kr.modumoa.hdapp.audio

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect

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
    Text("마이크 권한: ${if (permissions.microphone) "허용됨" else "필요함"}")
    if (!permissions.microphone || !permissions.notifications) {
        Button(onClick = permissions.request) { Text("마이크·알림 권한 요청") }
        if (!permissions.notifications) Text("통화 알림을 보려면 알림 권한을 허용해 주세요.")
        TextButton(onClick = {
            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
        }) { Text("앱 권한 설정 열기") }
    }
}
