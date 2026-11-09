package kr.modumoa.unavonoise

import java.nio.ByteBuffer

object RnnoiseBridge {
    init {
        System.loadLibrary("unavo_noise")
    }

    external fun create(): Long
    external fun process(state: Long, buffer: ByteBuffer, frames: Int): Float
    external fun destroy(state: Long)
}
