package kr.modumoa.unavonoise

import android.content.Context
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

class UnavoNoisePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val processor = RnnoiseProcessor()
    private var captureAdapter: AudioProcessingAdapter? = null
    private lateinit var appContext: Context
    private var processingEnabled = false
    private val exportLock = Any()
    private var exportServer: ServerSocket? = null
    private var exportClient: Socket? = null
    private var exportGeneration = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "unavo/noise").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure", "setEnabled" -> configure(call, result)
            "exportDump" -> exportDump(call, result)
            "status" -> result.success(
                mapOf(
                    "supported" to true,
                    "enabled" to (captureAdapter != null && processingEnabled),
                    "exportPort" to synchronized(exportLock) {
                        exportServer?.takeUnless { it.isClosed }?.localPort ?: 0
                    },
                ) + processor.status(),
            )
            else -> result.notImplemented()
        }
    }

    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled")
        if (enabled == null) {
            result.error("invalid_arguments", "enabled must be a bool", null)
            return
        }
        val dumpSeconds = if (call.method == "setEnabled") {
            0
        } else {
            call.argument<Int>("dumpSeconds") ?: 0
        }
        val floor = call.argument<Boolean>("floor") ?: true

        val controller = FlutterWebRTCPlugin.sharedSingleton?.audioProcessingController
        if (controller == null) {
            result.error(
                "webrtc_not_initialized",
                "Call getUserMedia or createPeerConnection before enabling RNNoise",
                null,
            )
            return
        }

        if (enabled || dumpSeconds > 0) {
            val adapter = controller.capturePostProcessing
            if (captureAdapter !== adapter) {
                detachProcessor()
                adapter.addProcessor(processor)
                captureAdapter = adapter
            }
        } else {
            detachProcessor()
        }
        processor.setFloorEnabled(floor)
        processor.setProcessing(enabled)
        processingEnabled = enabled
        if (dumpSeconds > 0) {
            processor.startDump(appContext.getExternalFilesDir(null)!!, dumpSeconds)
        } else {
            processor.stopDump()
        }
        result.success(
            if (call.method == "setEnabled") enabled
            else mapOf("enabled" to enabled, "dumpSeconds" to dumpSeconds),
        )
    }

    private fun exportDump(call: MethodCall, result: MethodChannel.Result) {
        val port = call.argument<Int>("port")
        if (port == null || port !in 1..65535) {
            result.error("invalid_arguments", "port must be between 1 and 65535", null)
            return
        }
        val generation = synchronized(exportLock) { exportGeneration }
        Thread({
            val server = try {
                synchronized(exportLock) {
                    if (generation != exportGeneration) {
                        result.error("export_detached", "Plugin detached before export started", null)
                        return@Thread
                    }
                    exportServer?.takeUnless { it.isClosed }?.let {
                        result.success(mapOf("port" to it.localPort, "running" to true))
                        return@Thread
                    }
                    ServerSocket(port, 1, InetAddress.getLoopbackAddress()).also {
                        exportServer = it
                    }
                }
            } catch (error: Exception) {
                Log.w("UNAVO_NOISE", "export start port=$port", error)
                result.error("export_failed", error.message, null)
                return@Thread
            }
            result.success(mapOf("port" to server.localPort, "running" to true))
            serveExport(server)
        }, "unavo-capture-export").apply {
            isDaemon = true
            start()
        }
    }

    private fun serveExport(server: ServerSocket) {
        try {
            while (!server.isClosed) {
                val client = server.accept()
                try {
                    client.use {
                        synchronized(exportLock) {
                            if (exportServer !== server || server.isClosed) return@use
                            exportClient = client
                        }
                        client.soTimeout = 5000
                        handleExport(client)
                    }
                } catch (error: Exception) {
                    if (!server.isClosed) Log.w("UNAVO_NOISE", "export request", error)
                } finally {
                    synchronized(exportLock) {
                        if (exportClient === client) exportClient = null
                    }
                }
            }
        } catch (error: Exception) {
            if (!server.isClosed) Log.w("UNAVO_NOISE", "export accept", error)
        } finally {
            synchronized(exportLock) {
                if (exportServer === server) exportServer = null
            }
            try {
                server.close()
            } catch (error: Exception) {
                Log.w("UNAVO_NOISE", "export close server", error)
            }
        }
    }

    private fun handleExport(client: Socket) {
        val reader = client.getInputStream().bufferedReader(Charsets.US_ASCII)
        val request = reader.readLine()?.split(' ') ?: return
        // 헤더를 끝까지 소비하고 응답 후 연결을 닫는다(keep-alive 없음).
        while (true) {
            val header = reader.readLine() ?: return
            if (header.isEmpty()) break
        }
        val output = client.getOutputStream()
        val dir = appContext.getExternalFilesDir(null)
        if (request.size != 3 || request[0] != "GET" || dir == null) {
            exportText(output, "404 Not Found", "not found\n")
            return
        }
        val target = request[1]
        when {
            target == "/list" -> {
                val body = captureFiles(dir).joinToString("") { "${it.name}\t${it.length()}\n" }
                exportText(output, "200 OK", body)
            }
            target == "/clear" -> {
                val files = captureFiles(dir)
                val active = processor.activeDumpPaths(files)
                var deleted = 0
                for (file in files) {
                    if (file.absolutePath in active) continue
                    if (file.delete()) {
                        deleted++
                    } else {
                        Log.w("UNAVO_NOISE", "export clear failed name=${file.name}")
                    }
                }
                exportText(output, "200 OK", "$deleted\n")
            }
            target.startsWith("/file/") -> {
                val file = captureFile(dir, target.removePrefix("/file/"))
                if (file == null) {
                    exportText(output, "404 Not Found", "not found\n")
                } else if (file.absolutePath in processor.activeDumpPaths(listOf(file))) {
                    exportText(output, "409 Conflict", "dump is still being written\n")
                } else {
                    file.inputStream().use { input ->
                        exportHeaders(output, "200 OK", "application/octet-stream", file.length())
                        input.copyTo(output, 64 * 1024)
                    }
                }
            }
            else -> exportText(output, "404 Not Found", "not found\n")
        }
    }

    private fun captureFile(dir: File, name: String): File? {
        if (!name.startsWith("capture-") || !name.endsWith(".pcm") ||
            '/' in name || '\\' in name || ".." in name
        ) return null
        val file = File(dir, name)
        return file.takeIf { it.isFile && it.canonicalFile == File(dir.canonicalFile, name) }
    }

    private fun captureFiles(dir: File): List<File> =
        dir.list()?.mapNotNull { captureFile(dir, it) }?.sortedBy { it.name }.orEmpty()

    private fun exportText(output: OutputStream, status: String, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        exportHeaders(output, status, "text/plain; charset=utf-8", bytes.size.toLong())
        output.write(bytes)
    }

    private fun exportHeaders(output: OutputStream, status: String, type: String, length: Long) {
        output.write(
            ("HTTP/1.0 $status\r\nContent-Type: $type\r\nContent-Length: $length\r\n" +
                "Connection: close\r\n\r\n").toByteArray(Charsets.US_ASCII),
        )
    }

    private fun closeExport() {
        synchronized(exportLock) {
            exportGeneration++
            try {
                exportServer?.close()
            } catch (error: Exception) {
                Log.w("UNAVO_NOISE", "export close server", error)
            }
            exportServer = null
            try {
                exportClient?.close()
            } catch (error: Exception) {
                Log.w("UNAVO_NOISE", "export close client", error)
            }
            exportClient = null
        }
    }

    private fun detachProcessor() {
        captureAdapter?.removeProcessor(processor)
        captureAdapter = null
        processingEnabled = false
        processor.release()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        closeExport()
        detachProcessor()
    }
}
