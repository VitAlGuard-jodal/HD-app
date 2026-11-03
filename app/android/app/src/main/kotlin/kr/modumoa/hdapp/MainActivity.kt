package kr.modumoa.hdapp

import android.content.Intent
import android.media.AudioManager
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kr.modumoa.hdapp.audio.AudioChannel
import kr.modumoa.hdapp.call.CallChannel
import kr.modumoa.hdapp.call.CallForegroundService

class MainActivity : FlutterActivity() {
    private var audioChannel: AudioChannel? = null
    private var callChannel: CallChannel? = null
    private var deviceChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeControlStream = AudioManager.STREAM_VOICE_CALL
        val app = application as UnavoApplication
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        deviceChannel = MethodChannel(messenger, "unavo/device").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAutomotive" -> result.success(packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE))
                    "hasMicrophone" -> result.success(packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE))
                    else -> result.notImplemented()
                }
            }
        }
        app.pendingOpenRoom = intent?.getStringExtra(CallForegroundService.EXTRA_ROOM_CODE)
        audioChannel = AudioChannel(this, app, messenger)
        callChannel = CallChannel(app, messenger)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(CallForegroundService.EXTRA_ROOM_CODE)?.let { code ->
            val app = application as UnavoApplication
            app.pendingOpenRoom = code
            app.callActions.tryEmit(mapOf("event" to "openRoom", "roomCode" to code))
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        audioChannel?.onPermissionsResult(requestCode)
    }

    override fun onResume() {
        super.onResume()
        audioChannel?.onActivityVisible()
    }

    override fun onPause() {
        audioChannel?.stopPreviewWhenHidden()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        audioChannel?.dispose()
        callChannel?.dispose()
        deviceChannel?.setMethodCallHandler(null)
        audioChannel = null
        callChannel = null
        deviceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
