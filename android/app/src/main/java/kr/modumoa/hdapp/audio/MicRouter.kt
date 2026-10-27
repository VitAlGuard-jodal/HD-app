package kr.modumoa.hdapp.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class MicState(
    val mode: MicMode,
    val devices: List<MicDevice> = emptyList(),
    val selected: MicDevice? = null,
    val manualId: Int? = null,
    val level: Float = 0f,
    val rms: Int = 0,
    val isRecording: Boolean = false,
    val error: String? = null,
)

class MicRouter(context: Context) {
    private val appContext = context.applicationContext
    private val manager = checkNotNull(appContext.getSystemService(AudioManager::class.java))
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val routeLock = Mutex()
    private val mutableState = MutableStateFlow(MicState(detectMode()))
    val state: StateFlow<MicState> = mutableState.asStateFlow()
    private var enabled = false
    private var audioConfigured = false
    private var focusRequest: AudioFocusRequest? = null
    private var recorder: AudioRecord? = null
    private var meterJob: Job? = null
    private var recordingDeviceId: Int? = null

    private val callback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = devicesChanged()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = devicesChanged()
    }

    init {
        manager.registerAudioDeviceCallback(callback, Handler(Looper.getMainLooper()))
        refreshSelection()
    }

    fun detectMode(): MicMode = if (appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
        MicMode.CAR
    } else {
        MicMode.PHONE
    }

    fun listInputs(): List<MicDevice> = manager.getDevices(AudioManager.GET_DEVICES_INPUTS).map {
        MicDevice(it.id, it.type, it.productName.toString().ifBlank { "입력 장치 ${it.id}" })
    }

    // 선택은 UI에서도 가능하지만 녹음 시작·종료는 통화 서비스가 소유한다.
    fun choose(manualId: Int?): MicDevice? {
        mutableState.update { it.copy(manualId = manualId, error = null) }
        devicesChanged()
        return state.value.selected
    }

    suspend fun apply(chosen: MicDevice) = withContext(Dispatchers.Main.immediate) {
        routeLock.withLock {
            enabled = true
            try {
                applyLocked(chosen)
            } catch (error: Exception) {
                releaseLocked()
                if (error is CancellationException) throw error
                mutableState.update { it.copy(error = error.message ?: "마이크를 시작하지 못했습니다.") }
                throw error
            }
        }
    }

    suspend fun release() = withContext(NonCancellable + Dispatchers.Main.immediate) {
        routeLock.withLock { releaseLocked() }
    }

    private fun refreshSelection() {
        val inputs = listInputs()
        val mode = detectMode()
        val ranked = MicRanker.rank(mode, inputs)
        val manual = ranked.firstOrNull { it.id == state.value.manualId }
        val chosen = manual ?: ranked.firstOrNull()
        mutableState.update { it.copy(mode = mode, devices = inputs, selected = chosen, manualId = manual?.id) }
        Log.i(TAG, "mode=${if (mode == MicMode.CAR) "car" else "phone"}")
        Log.i(TAG, "inputs=[${inputs.joinToString(",") { "${it.type}:${it.name}" }}]")
        chosen?.let { Log.i(TAG, "chosen=${it.type}:${it.name}") }
    }

    private fun devicesChanged() {
        refreshSelection()
        if (!enabled) return
        scope.launch {
            routeLock.withLock {
                if (!enabled) return@withLock
                try {
                    val chosen = state.value.selected ?: error("사용 가능한 마이크가 없습니다.")
                    applyLocked(chosen)
                } catch (error: Exception) {
                    releaseLocked()
                    if (error is CancellationException) throw error
                    mutableState.update { it.copy(error = error.message ?: "마이크 경로를 변경하지 못했습니다.") }
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private suspend fun applyLocked(chosen: MicDevice) {
        if (recorder != null && recordingDeviceId == chosen.id && state.value.isRecording) return
        check(ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED) { "마이크 권한을 허용해 주세요." }
        val available = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val input = available.firstOrNull { it.id == chosen.id } ?: error("선택한 마이크가 연결되어 있지 않습니다.")
        check(MicRanker.rank(detectMode(), listOf(chosen)).isNotEmpty()) { "통화 입력으로 사용할 수 없는 장치입니다." }
        stopCaptureLocked()
        audioConfigured = true
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (focusRequest == null) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener({ change ->
                    if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                        scope.launch {
                            if (enabled) {
                                release()
                                mutableState.update { it.copy(error = "다른 오디오가 우선되어 마이크를 중지했습니다. 다시 참여해 주세요.") }
                            }
                        }
                    }
                }, Handler(Looper.getMainLooper()))
                .build()
            focusRequest = request
            check(manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                "통화 오디오 포커스를 얻지 못했습니다. 다시 참여해 주세요."
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // 입력 ID와 일치하는 통신 장치가 없으면 AudioRecord의 입력 선호를 사용한다.
            manager.clearCommunicationDevice()
            manager.availableCommunicationDevices.firstOrNull { it.id == chosen.id }?.let {
                check(manager.setCommunicationDevice(it)) { "통신 장치 경로를 적용하지 못했습니다." }
            }
        }
        val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0) { "이 기기는 16 kHz 마이크 입력을 지원하지 않습니다." }
        val record = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(minimum, SAMPLES_PER_FRAME * 2 * 2))
            .build()
        recorder = record
        check(record.state == AudioRecord.STATE_INITIALIZED) { "마이크를 초기화하지 못했습니다." }
        check(record.setPreferredDevice(input)) { "선택한 마이크를 입력으로 지정하지 못했습니다." }
        record.startRecording()
        check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "마이크 녹음을 시작하지 못했습니다." }
        recordingDeviceId = chosen.id
        // 전환을 기다리는 사이 변경된 수동 선택은 덮어쓰지 않는다.
        mutableState.update { it.copy(isRecording = true, error = null, level = 0f, rms = 0) }
        Log.i(TAG, "chosen=${chosen.type}:${chosen.name}")
        meterJob = scope.launch(Dispatchers.IO) {
            val samples = ShortArray(SAMPLES_PER_FRAME)
            try {
                while (currentCoroutineContext().isActive) {
                    val started = System.nanoTime()
                    var filled = 0
                    while (filled < samples.size && currentCoroutineContext().isActive) {
                        val count = record.read(samples, filled, samples.size - filled, AudioRecord.READ_BLOCKING)
                        check(count > 0) { "마이크 읽기에 실패했습니다. ($count)" }
                        filled += count
                    }
                    if (!currentCoroutineContext().isActive) break
                    val rms = sqrt(samples.sumOf { it.toDouble() * it.toDouble() } / samples.size)
                    mutableState.update { it.copy(rms = rms.roundToInt(), level = (rms / 32768.0).toFloat().coerceIn(0f, 1f)) }
                    Log.d(TAG, "rms=${rms.roundToInt()}")
                    val remaining = 100L - (System.nanoTime() - started) / 1_000_000
                    if (remaining > 0) delay(remaining)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                if (currentCoroutineContext().isActive) scope.launch {
                    if (recorder === record) {
                        release()
                        mutableState.update { it.copy(error = error.message ?: "마이크 입력이 중단되었습니다.") }
                    }
                }
            }
        }
    }

    private suspend fun stopCaptureLocked() = withContext(NonCancellable) {
        val record = recorder
        recorder = null
        meterJob?.cancel()
        // stop으로 블로킹 read를 풀고 읽기 작업이 끝난 다음 네이티브 자원을 해제한다.
        if (record != null) runCatching { record.stop() }
        meterJob?.join()
        meterJob = null
        record?.release()
        recordingDeviceId = null
        mutableState.update { it.copy(isRecording = false, rms = 0, level = 0f) }
    }

    private suspend fun releaseLocked() = withContext(NonCancellable) {
        enabled = false
        stopCaptureLocked()
        if (audioConfigured) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) runCatching { manager.clearCommunicationDevice() }
            runCatching { manager.mode = AudioManager.MODE_NORMAL }
            focusRequest?.let { runCatching { manager.abandonAudioFocusRequest(it) } }
        }
        focusRequest = null
        audioConfigured = false
    }

    companion object {
        private const val TAG = "HDAUDIO"
        private const val SAMPLE_RATE = 16_000
        private const val SAMPLES_PER_FRAME = 1_600
    }
}
