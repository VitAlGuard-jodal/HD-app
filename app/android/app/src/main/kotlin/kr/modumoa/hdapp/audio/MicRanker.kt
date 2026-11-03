package kr.modumoa.hdapp.audio

data class MicDevice(val id: Int, val type: Int, val name: String, val webrtcDeviceId: String = id.toString())
enum class MicMode { CAR, PHONE }

object MicRanker {
    // AudioDeviceInfo의 정숫값을 사용하여 JVM에서도 같은 정책을 검증한다.
    private const val BUILTIN_MIC = 15
    private val headsets = setOf(7, 22, 3) // BLUETOOTH_SCO, USB_HEADSET, WIRED_HEADSET
    private val excluded = setOf(28, 16, 25, 18, 21) // ECHO_REFERENCE, FM_TUNER, REMOTE_SUBMIX, TELEPHONY, BUS

    fun rank(mode: MicMode, devices: List<MicDevice>): List<MicDevice> =
        devices.filterNot { it.type in excluded }.sortedBy {
            // 같은 우선순위의 입력은 기기가 보고한 순서를 보존한다.
            when (mode) {
                MicMode.CAR -> when {
                    it.type == BUILTIN_MIC -> 0
                    it.type in headsets -> 1
                    else -> 2
                }
                MicMode.PHONE -> when {
                    it.type in headsets -> 0
                    it.type == BUILTIN_MIC -> 1
                    else -> 2
                }
            }
        }
}
