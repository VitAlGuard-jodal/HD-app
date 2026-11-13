package kr.modumoa.hdapp.tts

import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import ai.pleos.playground.tts.TextToSpeech
import ai.pleos.playground.tts.constant.ErrorType
import ai.pleos.playground.tts.constant.Mode
import ai.pleos.playground.tts.listener.EventListener
import ai.pleos.playground.tts.listener.OnInitializeListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class TtsChannel(context: Context, messenger: BinaryMessenger) {
    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "unavo/tts")
    private val audio by lazy { checkNotNull(this.context.getSystemService(AudioManager::class.java)) }
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private var sdk: TextToSpeech? = null
    private var ready = false
    private var initializing = false
    private var disabled = false
    private var closing = false
    private var active = false
    private var stopping = false
    private var sequence = 0
    private var pending: Speech? = null
    private var focus: AudioFocusRequest? = null
    private val stopResults = mutableListOf<MethodChannel.Result>()
    private var initializeTimeout: Runnable? = null
    private var speechTimeout: Runnable? = null
    private var stopTimeout: Runnable? = null

    private class Speech(val text: String, val expiresAt: Long, var result: MethodChannel.Result?, val id: Int)

    private val listener = object : EventListener {
        override fun onStart() { main.post { Log.d(TAG, "onStart id=${pending?.id}") } }
        override fun onReady() { main.post { Log.d(TAG, "onReady id=${pending?.id}") } }
        override fun onDone() { main.post { Log.d(TAG, "onDone id=${pending?.id}"); finish(true) } }
        override fun onStop() { main.post { Log.d(TAG, "onStop id=${pending?.id}"); finish(false) } }
        override fun onError(errorType: ErrorType) {
            main.post { Log.w(TAG, "onError $errorType id=${pending?.id}"); finish(false) }
        }
        override fun onUpdatedRms(rms: Double) = Unit
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    val text = call.argument<String>("text")
                    val expires = call.argument<Number>("expiresAt")?.toLong() ?: 0
                    if (text.isNullOrBlank() || expires <= System.currentTimeMillis() ||
                        closing || disabled || pending != null || active || stopping ||
                        !this.context.packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
                        result.success(false)
                    } else {
                        pending = Speech(text, expires, result, ++sequence)
                        if (ready) play() else initialize()
                    }
                }
                "stop" -> { stopResults.add(result); stop() }
                else -> result.notImplemented()
            }
        }
    }

    private fun initialize() {
        if (initializing) return
        guarded({
            initializing = false
            initializeTimeout?.let(main::removeCallbacks)
            initializeTimeout = null
            disable("initialize $it")
        }) {
            val engine = sdk ?: TextToSpeech(context, Mode.ON_DEVICE).also { sdk = it }
            initializing = true
            initializeTimeout = Runnable {
                // The bind callback may still arrive. Do not release in-flight SDK
                // initialization; complete Dart and release after that callback.
                disable("initialize timeout")
            }.also { main.postDelayed(it, 8000) }
            engine.initialize(object : OnInitializeListener {
                override fun onSuccess() {
                    main.post {
                        initializing = false
                        initializeTimeout?.let(main::removeCallbacks)
                        initializeTimeout = null
                        if (closing || disabled) { releaseIfIdle(); return@post }
                        guarded({ disable("configure $it") }) {
                            engine.setLocale(Locale.KOREA)
                            engine.setAudioAttributes(attributes)
                            engine.addEventListener(listener)
                            ready = true
                            Log.d(TAG, "initialized ON_DEVICE ko-KR NAVIGATION/SPEECH")
                            play()
                        }
                    }
                }
                override fun onFailure(errorType: ErrorType) {
                    main.post {
                        initializing = false
                        initializeTimeout?.let(main::removeCallbacks)
                        initializeTimeout = null
                        disable("initialize onError $errorType")
                        releaseIfIdle()
                    }
                }
            })
        }
    }

    private fun play() {
        val speech = pending ?: return
        if (!ready || closing || disabled || System.currentTimeMillis() >= speech.expiresAt) {
            completePending(false)
            return
        }
        guarded({ disable("focus $it") }) {
            lateinit var request: AudioFocusRequest
            request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attributes)
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener({ change ->
                    if (focus === request && change < 0) {
                        Log.d(TAG, "focus lost=$change; stop guidance")
                        stop()
                    }
                }, main).build()
            focus = request
            if (audio.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                Log.w(TAG, "focus denied; skip guidance")
                completePending(false)
                abandonFocus()
                return@guarded
            }
            // SDK owns PCM/playback. This settle delay is only the guide's
            // last-resort scheduling option, not guaranteed PCM silence padding.
            main.postDelayed({
                if (pending !== speech || closing || disabled) return@postDelayed
                if (System.currentTimeMillis() >= speech.expiresAt) {
                    completePending(false)
                    abandonFocus()
                    return@postDelayed
                }
                guarded({ disable("speak $it") }) {
                    active = true
                    Log.d(TAG, "speak id=${speech.id} chars=${speech.text.length}")
                    speechTimeout = Runnable {
                        Log.w(TAG, "onError callback timeout id=${speech.id}")
                        stop()
                    }.also { main.postDelayed(it, 15000) }
                    checkNotNull(sdk).speak(speech.text, true)
                }
            }, 180)
        }
    }

    private fun stop() {
        speechTimeout?.let(main::removeCallbacks)
        speechTimeout = null
        if (!active) {
            completePending(false) // also invalidates a delayed play/initialization
            abandonFocus()
            completeStops(true)
            releaseIfIdle()
            return
        }
        // Keep the old utterance alive until its terminal SDK callback, so a
        // late onStop cannot accidentally complete the next utterance.
        pending?.result?.success(false)
        pending?.result = null
        if (stopping) return
        stopping = true
        stopTimeout = Runnable {
            disabled = true
            Log.w(TAG, "onError stop timeout; disable further speech")
            completeStops(false)
            abandonFocus()
            // Still retain SDK until terminal callback (or process death).
        }.also { main.postDelayed(it, 2000) }
        guarded({
            disabled = true
            Log.w(TAG, "stop $it")
            completeStops(false)
            abandonFocus()
        }) { sdk?.stop() }
    }

    private fun finish(success: Boolean) {
        if (!active) return
        active = false
        stopping = false
        speechTimeout?.let(main::removeCallbacks)
        stopTimeout?.let(main::removeCallbacks)
        speechTimeout = null
        stopTimeout = null
        completePending(success)
        completeStops(true)
        abandonFocus()
        releaseIfIdle()
    }

    private fun completePending(success: Boolean) {
        val speech = pending
        pending = null
        speech?.result?.success(success)
        speech?.result = null
    }

    private fun completeStops(success: Boolean) {
        val results = stopResults.toList()
        stopResults.clear()
        results.forEach { it.success(success) }
    }

    private fun disable(reason: String) {
        Log.w(TAG, "onError $reason")
        disabled = true
        if (active) stop() else {
            completePending(false)
            abandonFocus()
        }
    }

    private fun abandonFocus() {
        val request = focus ?: return
        focus = null
        guarded({ Log.w(TAG, "abandonFocus $it") }) { audio.abandonAudioFocusRequest(request) }
    }

    fun dispose() {
        if (closing) return
        closing = true
        channel.setMethodCallHandler(null)
        stop()
    }

    private fun releaseIfIdle() {
        if (!closing || initializing || active) return
        val engine = sdk ?: return
        sdk = null
        // All SDK callbacks are marshalled to main; this runs after their stack.
        if (ready) guarded({ Log.w(TAG, "removeListener $it") }) { engine.removeEventListener(listener) }
        ready = false
        guarded({ Log.w(TAG, "release $it") }) { engine.release() }
    }

    private inline fun guarded(failure: (String) -> Unit, block: () -> Unit) {
        try { block() }
        catch (error: Exception) { failure(error.javaClass.simpleName) }
        catch (error: LinkageError) { failure(error.javaClass.simpleName) }
    }

    private companion object { const val TAG = "unavo-tts" }
}
