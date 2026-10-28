package kr.modumoa.hdapp.ui

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.vectorResource
import kr.modumoa.hdapp.R

// 기존 호출부의 아이콘 의미를 유지하며 정본의 1.8/24 선형 아이콘으로 그린다.
@Composable
fun modumoaIcon(icon: ImageVector): ImageVector {
    val resource = when (icon.name.substringAfterLast('.')) {
        "ArrowForward" -> R.drawable.ui_arrow
        "ArrowBack" -> R.drawable.ui_back
        "Logout", "ExitToApp" -> R.drawable.ui_exit
        "Call", "AddIcCall" -> R.drawable.ui_phone
        "CallEnd" -> R.drawable.ui_hangup
        "Mic", "SettingsVoice" -> R.drawable.ui_mic
        "MicOff" -> R.drawable.ui_micoff
        "Add" -> R.drawable.ui_plus
        "Delete" -> R.drawable.ui_trash
        "Refresh" -> R.drawable.ui_refresh
        "GraphicEq" -> R.drawable.ui_wave
        "Groups" -> R.drawable.ui_rooms
        "Contacts" -> R.drawable.ui_friends
        "Check", "CheckCircle" -> R.drawable.ui_check
        "Lock" -> R.drawable.ui_lock
        "Person", "AlternateEmail" -> R.drawable.ui_user
        "DirectionsCar" -> R.drawable.ui_car
        "Smartphone" -> R.drawable.ui_mobile
        "Headset" -> R.drawable.ui_headset
        else -> return icon
    }
    return ImageVector.vectorResource(resource)
}

@Composable
fun VehicleIcon(contentDescription: String? = null) {
    Icon(painterResource(R.drawable.ui_car), contentDescription, Modifier.size(IconSecondary),
        tint = MaterialTheme.colorScheme.primary)
}
