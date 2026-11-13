package kr.modumoa.hdapp.location

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import ai.pleos.playground.location.fused.FusedLocation
import ai.pleos.playground.location.fused.listener.FusedLocationListener
import ai.pleos.playground.location.fused.model.LocationData
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class LocationChannel(private val activity: Activity, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "unavo/location")
    private val events = EventChannel(messenger, "unavo/location/events")
    private var sdk: FusedLocation? = null
    private var initialized = false
    private var disposed = false
    private var permissionResult: MethodChannel.Result? = null
    private var listener: FusedLocationListener? = null
    private var sink: EventChannel.EventSink? = null

    init {
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
            Log.d(TAG, "source=geolocator (phone)")
        }
        events.setStreamHandler(this)
        methods.setMethodCallHandler { call, result ->
            if (call.method == "prepare") prepare(result) else result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        if (disposed || !activity.packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
            fallback("not automotive", result)
            return
        }
        if (permissionResult != null) {
            fallback("permission request pending", result)
            return
        }
        guarded({ fallback(it, result) }) {
            val location = sdk ?: FusedLocation(activity.applicationContext).also { sdk = it }
            if (!location.isSupported()) {
                fallback("unsupported", result)
            } else if (activity.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED) {
                initialize(result)
            } else {
                permissionResult = result
                try {
                    activity.requestPermissions(arrayOf(PERMISSION), REQUEST_CODE)
                } catch (error: Exception) {
                    permissionResult = null
                    throw error
                }
            }
        }
    }

    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != REQUEST_CODE) return
        val result = permissionResult ?: return
        permissionResult = null
        if (!disposed && activity.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED) {
            initialize(result)
        } else {
            fallback("permission denied", result)
        }
    }

    private fun initialize(result: MethodChannel.Result) = guarded({ fallback(it, result) }) {
        if (!initialized) {
            checkNotNull(sdk).initialize()
            initialized = true
        }
        result.success(true)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        onCancel(null)
        sink = eventSink
        if (disposed || !initialized) {
            fail("not initialized", eventSink)
            return
        }
        val callback = object : FusedLocationListener {
            override fun onChanged(location: LocationData?) {
                // Binder callbacks never access a released SDK or a cancelled sink.
                main.post {
                    if (disposed || listener !== this || sink !== eventSink || location == null) return@post
                    Log.d(TAG, "sample timestampMillis=${location.timestampMillis}")
                    eventSink.success(mapOf(
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                        "altitude" to location.altitude,
                        "heading" to location.heading.toDouble(),
                        "confidence" to location.confidence.toDouble(),
                        "timestampMillis" to location.timestampMillis,
                    ))
                }
            }

            override fun onError(exception: Exception) {
                main.post {
                    if (!disposed && listener === this && sink === eventSink) {
                        fail(exception.javaClass.simpleName, eventSink)
                    }
                }
            }
        }
        listener = callback
        guarded({ fail(it, eventSink) }) {
            checkNotNull(sdk).registerFusedLocationCallback(callback)
            Log.d(TAG, "source=FusedLocation register")
        }
    }

    private fun fail(reason: String, eventSink: EventChannel.EventSink) {
        onCancel(null)
        Log.w(TAG, "source=geolocator fallback=$reason")
        eventSink.error("fused_unavailable", reason, null)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        val callback = listener ?: return
        listener = null
        guarded({ Log.w(TAG, "unregister: $it") }) {
            sdk?.unregisterFusedLocationCallback(callback)
            Log.d(TAG, "FusedLocation unregister")
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        onCancel(null)
        permissionResult?.success(false)
        permissionResult = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        // Release at engine teardown, after unregister and the current callback
        // stack. Room/share stop only unregisters; it never releases the SDK.
        main.post {
            guarded({ Log.w(TAG, "release: $it") }) { sdk?.release() }
            sdk = null
            initialized = false
        }
    }

    private fun fallback(reason: String, result: MethodChannel.Result) {
        Log.d(TAG, "source=geolocator fallback=$reason")
        result.success(false)
    }

    private inline fun guarded(failure: (String) -> Unit, block: () -> Unit) {
        try { block() }
        catch (error: Exception) { failure(error.javaClass.simpleName) }
        catch (error: LinkageError) { failure(error.javaClass.simpleName) }
    }

    private companion object {
        const val TAG = "unavo-location"
        const val PERMISSION = "pleos.car.permission.FUSED_LOCATION"
        const val REQUEST_CODE = 7402
    }
}
