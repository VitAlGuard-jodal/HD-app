package kr.modumoa.unavonoise

import android.util.Log
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

class RnnoiseProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private val lock = Any()
    private var sampleRate = 0
    private var channels = 0
    private var frames = 0
    private var processed = 0L
    private var bypassed = 0L
    private var lastVad = 0.0f
    private var handle = 0L
    @Volatile private var processing = true
    private var dump: CaptureDump? = null
    // 덤프를 교체해도 writer는 하나만 사용하며, 유휴 상태가 되면 스레드를 정리한다.
    private val dumpWriter = ThreadPoolExecutor(
        0, 1, 1L, TimeUnit.SECONDS, LinkedBlockingQueue<Runnable>(),
        { task -> Thread(task, "unavo-capture-dump").apply { isDaemon = true } },
    )

    fun setProcessing(value: Boolean) {
        processing = value
    }

    fun startDump(dir: File, seconds: Int) {
        synchronized(lock) {
            dump?.stop()
            if (seconds > 0) {
                val next = CaptureDump(dir, seconds)
                dump = next
                dumpWriter.execute { next.write() }
            }
        }
    }

    fun stopDump() {
        synchronized(lock) {
            dump?.stop()
        }
    }

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        synchronized(lock) {
            channels = numChannels
            initializeLocked(sampleRateHz)
        }
    }

    override fun reset(newRate: Int) {
        synchronized(lock) {
            initializeLocked(newRate)
        }
    }

    private fun initializeLocked(rate: Int) {
        releaseLocked()
        sampleRate = rate
        lastVad = 0.0f
        if (rate == 48000) {
            handle = RnnoiseBridge.create()
        } else {
            Log.w("UNAVO_NOISE", "bypass: rate=$rate ch=$channels (48000 필요)")
        }
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        synchronized(lock) {
            frames = numFrames
            // flutter_webrtc 의 AudioProcessingAdapter 는 뒤늦게 추가된 프로세서에 initialize 를
            // 다시 불러 주지 않는다. 10 ms 프레임이므로 numFrames*100 이 곧 샘플레이트다.
            if (sampleRate != numFrames * 100) {
                initializeLocked(numFrames * 100)
            }
            val processAudio = processing
            val activeDump = dump
            val dumpFrame = activeDump?.captureInput(buffer, numFrames, sampleRate, processAudio)
            if (!processAudio || handle == 0L || numFrames != 480) {
                bypassed++
            } else {
                val vad = RnnoiseBridge.process(handle, buffer, numFrames)
                if (vad >= 0.0f) {
                    processed++
                    lastVad = vad
                } else {
                    bypassed++
                }
            }
            if (activeDump != null && dumpFrame != null) {
                activeDump.finishFrame(dumpFrame, buffer, numFrames)
            }
            logProgressLocked()
        }
    }

    private fun logProgressLocked() {
        if ((processed + bypassed) % 500L == 0L) {
            val vad = String.format(Locale.US, "%.2f", lastVad)
            Log.i(
                "UNAVO_NOISE",
                "rate=$sampleRate frames=$frames processed=$processed bypassed=$bypassed vad=$vad",
            )
        }
    }

    fun status(): Map<String, Any> = synchronized(lock) {
        mapOf(
            "sampleRate" to sampleRate,
            "channels" to channels,
            "frames" to frames,
            "processed" to processed,
            "bypassed" to bypassed,
            "vad" to lastVad.toDouble(),
            "dumpPath" to (dump?.path ?: ""),
            "dumpBytes" to (dump?.bytes ?: 0L),
            "dumpDropped" to (dump?.dropped ?: 0L),
        )
    }

    fun activeDumpPaths(candidates: Collection<File>): Set<String> = synchronized(lock) {
        // stop() 이후에도 큐 배출·flush·close가 끝날 때까지 writer는 살아 있다.
        if (dumpWriter.activeCount == 0 && dumpWriter.queue.isEmpty()) {
            return@synchronized emptySet()
        }
        val inputPath = dump?.path.orEmpty()
        if (inputPath.isEmpty()) {
            // 첫 프레임 전에는 파일이 없다. 교체 대기 중이면 이전 writer의 후보를 보호한다.
            return@synchronized if (dumpWriter.queue.isEmpty()) emptySet()
            else candidates.mapTo(mutableSetOf()) { it.absolutePath }
        }
        val inputFile = File(inputPath)
        setOf(
            inputPath,
            File(inputFile.parentFile, inputFile.name.replaceFirst("capture-in-", "capture-out-"))
                .absolutePath,
        )
    }

    fun release() {
        synchronized(lock) {
            dump?.stop()
            releaseLocked()
        }
    }

    private fun releaseLocked() {
        if (handle != 0L) {
            RnnoiseBridge.destroy(handle)
            handle = 0L
        }
    }

    private class CaptureDump(private val dir: File, private val seconds: Int) {
        // 입력과 출력을 같은 요소에 담아 큐가 가득 차면 같은 10 ms 구간을 함께 누락한다.
        private val queue = ArrayBlockingQueue<ByteArray>(3000)
        @Volatile private var accepting = true
        @Volatile var path = ""
            private set
        @Volatile var bytes = 0L
            private set
        @Volatile var dropped = 0L
            private set
        private var rate = 0
        private var withOutput = false
        private var capturedFrames = 0L

        fun captureInput(
            buffer: ByteBuffer,
            numFrames: Int,
            sampleRate: Int,
            processing: Boolean,
        ): ByteArray? {
            if (!accepting || numFrames <= 0) return null
            // 파일 하나에 서로 다른 샘플레이트를 섞지 않는다.
            if (rate != 0 && rate != sampleRate) {
                stop()
                return null
            }
            if (rate == 0) {
                rate = sampleRate
                withOutput = processing
            }
            val data = ByteArray(numFrames * if (withOutput) 4 else 2)
            copyPcm(buffer, data, 0, numFrames)
            return data
        }

        fun finishFrame(data: ByteArray, buffer: ByteBuffer, numFrames: Int) {
            if (!accepting) return
            if (withOutput) copyPcm(buffer, data, numFrames * 2, numFrames)
            if (!queue.offer(data)) dropped++
            capturedFrames += numFrames
            if (capturedFrames >= seconds.toLong() * rate) stop()
        }

        fun stop() {
            // producer는 processor의 lock 안에서만 호출한다. 파일 종료를 기다리지 않는다.
            accepting = false
        }

        private fun copyPcm(buffer: ByteBuffer, data: ByteArray, offset: Int, frames: Int) {
            // JNI와 같은 native float32를 읽되 원본 버퍼의 위치/순서/내용은 바꾸지 않는다.
            val floats = buffer.duplicate().order(ByteOrder.nativeOrder())
            for (index in 0 until frames) {
                val value = floats.getFloat(index * 4)
                val sample = if (value.isNaN()) 0 else value.roundToInt().coerceIn(-32768, 32767)
                data[offset + index * 2] = sample.toByte()
                data[offset + index * 2 + 1] = (sample shr 8).toByte()
            }
        }

        private fun nextFrame(): ByteArray? {
            while (true) {
                val data = queue.poll(100L, TimeUnit.MILLISECONDS)
                if (data != null) return data
                // poll 직후 마지막 프레임이 들어오고 stop된 경우에도 큐를 끝까지 비운다.
                if (!accepting) return queue.poll()
            }
        }

        fun write() {
            try {
                // 첫 process가 보낸 프레임으로 rate/출력 여부를 확정한 뒤 writer에서 연다.
                var frame = nextFrame() ?: return
                val format = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
                var time = System.currentTimeMillis()
                var stamp = format.format(Date(time))
                var inputFile = File(dir, "capture-in-$stamp-${rate}hz.pcm")
                var outputFile = File(dir, "capture-out-$stamp-${rate}hz.pcm")
                // 같은 초에 다시 시작해도 앞선 덤프를 덮어쓰지 않는다.
                while (inputFile.exists() || (withOutput && outputFile.exists())) {
                    time += 1000L
                    stamp = format.format(Date(time))
                    inputFile = File(dir, "capture-in-$stamp-${rate}hz.pcm")
                    outputFile = File(dir, "capture-out-$stamp-${rate}hz.pcm")
                }
                path = inputFile.absolutePath
                BufferedOutputStream(FileOutputStream(inputFile), 64 * 1024).use { input ->
                    val output = if (withOutput) {
                        BufferedOutputStream(FileOutputStream(outputFile), 64 * 1024)
                    } else {
                        null
                    }
                    output.use { destination ->
                        Log.i("UNAVO_NOISE", "dump start path=$path")
                        while (true) {
                            val inputBytes = if (withOutput) frame.size / 2 else frame.size
                            input.write(frame, 0, inputBytes)
                            bytes += inputBytes
                            destination?.write(frame, inputBytes, inputBytes)
                            frame = nextFrame() ?: break
                        }
                    }
                }
            } catch (error: Exception) {
                Log.w("UNAVO_NOISE", "dump failed path=$path", error)
            } finally {
                accepting = false
                queue.clear()
                if (path.isNotEmpty()) {
                    Log.i("UNAVO_NOISE", "dump stop path=$path bytes=$bytes dropped=$dropped")
                }
            }
        }
    }
}
