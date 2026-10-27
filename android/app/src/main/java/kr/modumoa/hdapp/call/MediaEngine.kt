package kr.modumoa.hdapp.call

import android.util.Log

interface MediaEngine {
    fun join(roomCode: String, selfHandle: String)
    fun leave()
    fun setMuted(muted: Boolean)
    fun onSignal(from: String, kind: String, payload: Any?)

    // 설계 정본의 발화자 훅을 보존한다. 실제 미디어 엔진 연결 시 구현한다.
    fun onRemoteSpeaking(handle: String) {}
}

class NoopMediaEngine : MediaEngine {
    override fun join(roomCode: String, selfHandle: String) {
        Log.i(TAG, "join room=$roomCode self=$selfHandle (미디어 엔진 미연결)")
    }
    override fun leave() { Log.i(TAG, "leave") }
    override fun setMuted(muted: Boolean) { Log.i(TAG, "muted=$muted") }
    override fun onSignal(from: String, kind: String, payload: Any?) {
        Log.i(TAG, "signal from=$from kind=$kind")
    }
    override fun onRemoteSpeaking(handle: String) { Log.i(TAG, "speaking=$handle") }

    private companion object { const val TAG = "HDMEDIA" }
}
