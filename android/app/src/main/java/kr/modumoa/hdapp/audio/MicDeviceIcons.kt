package kr.modumoa.hdapp.audio

import android.media.AudioDeviceInfo
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Headset
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.SettingsInputComponent
import androidx.compose.material.icons.filled.Usb
import androidx.compose.ui.graphics.vector.ImageVector

fun iconFor(type: Int): ImageVector = when (type) {
    AudioDeviceInfo.TYPE_BUILTIN_MIC -> Icons.Filled.Mic
    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> Icons.Filled.Bluetooth
    AudioDeviceInfo.TYPE_WIRED_HEADSET -> Icons.Filled.Headset
    AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> Icons.Filled.Usb
    AudioDeviceInfo.TYPE_FM_TUNER -> Icons.Filled.Radio
    else -> Icons.Filled.SettingsInputComponent
}
