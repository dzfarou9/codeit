package com.farou9.codeit

import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity — Flutter entry point + MethodChannel / EventChannel bridge.
 *
 * Channel:  "com.farou9.codeit/engine"  (MethodChannel)
 * Event:    "com.farou9.codeit/ptyOutput" (EventChannel — bytes from PTY master)
 *
 * All native binaries are resolved via applicationInfo.nativeLibraryDir
 * (W^X compliance — never from filesDir).
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        const val METHOD_CHANNEL = "com.farou9.codeit/engine"
        const val EVENT_CHANNEL = "com.farou9.codeit/ptyOutput"
    }

    private var ptyBridge: PtyBridge? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingBytes: MutableList<ByteArray> = mutableListOf()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        ptyBridge = PtyBridge(this)

        // ---------- EventChannel (PTY stdout -> Dart) ----------
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                    ptyBridge?.onBytes = { data ->
                        runOnUiThread {
                            try {
                                eventSink?.success(data)
                            } catch (_: Exception) {
                                // Sink closed — buffer
                                pendingBytes.add(data)
                            }
                        }
                    }
                    // Flush pending
                    for (b in pendingBytes) {
                        try { sink.success(b) } catch (_: Exception) { break }
                    }
                    pendingBytes.clear()
                }

                override fun onCancel(args: Any?) {
                    ptyBridge?.onBytes = null
                    eventSink = null
                }
            })

        // ---------- MethodChannel ----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNativeLibDir" -> {
                        result.success(applicationInfo.nativeLibraryDir)
                    }

                    "getFilesDir" -> {
                        result.success(filesDir.absolutePath)
                    }

                    "resolveBinary" -> {
                        // Resolve libproot.so / libbash.so / libtar.so with
                        // nativeLibraryDir → assets fallback (see PtyBridge).
                        try {
                            val name = call.arguments as String
                            val path = ptyBridge?.resolveBinary(
                                name = name,
                                nativeLibDir = applicationInfo.nativeLibraryDir,
                                filesDir = filesDir.absolutePath,
                            )
                            if (path != null) {
                                result.success(path)
                            } else {
                                result.error(
                                    "BINARY_NOT_FOUND",
                                    "$name not found in nativeLibraryDir or assets/bin",
                                    null,
                                )
                            }
                        } catch (e: Exception) {
                            result.error("RESOLVE_FAILED", e.message, null)
                        }
                    }

                    "startPty" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            val args = call.arguments as Map<String, Any>
                            val cols = (args["cols"] as Number).toInt()
                            val rows = (args["rows"] as Number).toInt()
                            val rootfsPath = args["rootfsPath"] as? String
                                ?: "${filesDir.absolutePath}/rootfs"

                            // Ensure foreground service is running so the PTY
                            // child is not killed by Phantom Process Killer
                            PtyService.start(this)

                            val ok = ptyBridge!!.start(
                                cols = cols,
                                rows = rows,
                                filesDir = filesDir.absolutePath,
                                nativeLibDir = applicationInfo.nativeLibraryDir,
                                rootfsPath = rootfsPath,
                            )
                            if (ok) {
                                result.success(true)
                            } else {
                                val detail = ptyBridge!!.lastError.ifEmpty {
                                    "native start returned false (no detail captured)"
                                }
                                Log.e(TAG, "startPty failed: $detail")
                                result.error("PTY_START_FAILED", detail, null)
                            }
                        } catch (e: Exception) {
                            result.error("PTY_START_EXCEPTION", e.message, e.stackTraceToString())
                        }
                    }

                    "write" -> {
                        try {
                            val data = call.arguments as ByteArray
                            ptyBridge?.write(data)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", e.message, null)
                        }
                    }

                    "resize" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            val args = call.arguments as Map<String, Any>
                            val cols = (args["cols"] as Number).toInt()
                            val rows = (args["rows"] as Number).toInt()
                            ptyBridge?.resize(cols, rows)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RESIZE_FAILED", e.message, null)
                        }
                    }

                    "kill" -> {
                        ptyBridge?.kill()
                        PtyService.stop(this)
                        result.success(null)
                    }

                    "isInstalled" -> {
                        val rootfs = java.io.File(filesDir, "rootfs")
                        // Consider installed if rootfs contains /bin or /usr
                        val installed = rootfs.exists() &&
                            (java.io.File(rootfs, "bin").exists() ||
                                java.io.File(rootfs, "usr").exists() ||
                                java.io.File(rootfs, "etc").exists())
                        result.success(installed)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        // Do NOT kill PTY on Activity destroy — service keeps it alive.
        // Only clear sink.
        eventSink = null
        super.onDestroy()
    }
}
