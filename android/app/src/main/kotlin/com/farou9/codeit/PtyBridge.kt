package com.farou9.codeit

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * PtyBridge — Kotlin wrapper around the JNI PTY native layer.
 *
 * Binaries are resolved from nativeLibraryDir (W^X compliant).
 * The PTY is managed in native code (pty_bridge.c -> libpty.so).
 *
 * Flow:
 *  Dart --MethodChannel--> PtyBridge.start() --> nativePtyStart()
 *  native thread reads from PTY master fd --> callback --> EventChannel --> xterm.dart
 *  Dart writes --> PtyBridge.write() --> nativePtyWrite()
 *
 * NOTE: Never execute binaries from filesDir. All exec paths point to nativeLibraryDir.
 */
class PtyBridge(private val context: Context) {

    companion object {
        private const val TAG = "PtyBridge"
        init {
            try {
                System.loadLibrary("pty")
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load libpty.so — ensure it is in jniLibs/arm64-v8a", e)
            }
        }
    }

    /** Called on a background thread with raw bytes from the PTY master. */
    var onBytes: ((ByteArray) -> Unit)? = null

    private val running = AtomicBoolean(false)
    private var readerThread: Thread? = null

    // ---- JNI declarations (implemented in src/main/jni/pty_bridge.c) ----
    private external fun nativePtyStart(
        prootPath: String,
        bashPath: String,
        rootfsPath: String,
        filesDir: String,
        nativeLibDir: String,
        cols: Int,
        rows: Int,
    ): Int  // returns fd or -1

    private external fun nativePtyWrite(data: ByteArray, length: Int): Int
    private external fun nativePtyResize(cols: Int, rows: Int): Int
    private external fun nativePtyKill()
    private external fun nativePtyGetFd(): Int

    /**
     * Start the PRoot session.
     *
     * Resolves binary paths from nativeLibraryDir (W^X compliant).
     * Constructs the proot invocation:
     *   libproot.so -r <rootfs> -0 -b /dev -b /proc -b /sys
     *               -b /sdcard/Download:/mnt/download
     *               -b <filesDir>:/host
     *               -w /root /bin/bash --login
     */
    fun start(
        cols: Int,
        rows: Int,
        filesDir: String,
        nativeLibDir: String,
        rootfsPath: String,
    ): Boolean {
        if (running.get()) {
            Log.w(TAG, "PTY already running — killing previous session")
            kill()
            Thread.sleep(300)
        }

        val prootPath = "$nativeLibDir/libproot.so"
        val bashPath = "$nativeLibDir/libbash.so"
        // libtar.so is used separately during setup extraction (not here)

        if (!File(prootPath).exists()) {
            Log.e(TAG, "libproot.so not found at $prootPath — did you place it in jniLibs?")
            return false
        }
        if (!File(rootfsPath).exists()) {
            Log.e(TAG, "rootfs not found at $rootfsPath — run SetupScreen first")
            return false
        }

        Log.i(TAG, "Starting PTY: proot=$prootPath rootfs=$rootfsPath cols=$cols rows=$rows")

        val fd = nativePtyStart(
            prootPath = prootPath,
            bashPath = bashPath,
            rootfsPath = rootfsPath,
            filesDir = filesDir,
            nativeLibDir = nativeLibDir,
            cols = cols,
            rows = rows,
        )

        if (fd < 0) {
            Log.e(TAG, "nativePtyStart failed: fd=$fd")
            return false
        }

        running.set(true)
        startReaderLoop()
        Log.i(TAG, "PTY started, fd=$fd")
        return true
    }

    private fun startReaderLoop() {
        readerThread = thread(name = "pty-reader", isDaemon = true) {
            val buf = ByteArray(8192)
            // We poll via native read; the JNI layer exposes a blocking read helper.
            // For simplicity we call nativePtyReadAvailable if present, else busy poll.
            // Here we delegate to a helper that reads from the PTY fd set in native code.
            while (running.get()) {
                try {
                    val n = nativePtyRead(buf)
                    if (n > 0) {
                        val copy = buf.copyOf(n)
                        onBytes?.invoke(copy)
                    } else if (n < 0) {
                        Log.i(TAG, "PTY EOF / error n=$n — session ended")
                        running.set(false)
                        break
                    } else {
                        // n == 0 → no data, avoid spin
                        Thread.sleep(5)
                    }
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "Reader loop error", e)
                    Thread.sleep(50)
                }
            }
        }
    }

    // Blocking read from PTY master fd (implemented in native layer).
    private external fun nativePtyRead(buffer: ByteArray): Int

    fun write(data: ByteArray) {
        if (!running.get()) {
            Log.w(TAG, "write() called but PTY not running")
            return
        }
        nativePtyWrite(data, data.size)
    }

    fun resize(cols: Int, rows: Int) {
        Log.d(TAG, "resize cols=$cols rows=$rows")
        nativePtyResize(cols, rows)
    }

    fun kill() {
        if (!running.getAndSet(false)) return
        Log.i(TAG, "Killing PTY session")
        try { nativePtyKill() } catch (e: Exception) { Log.e(TAG, "kill failed", e) }
        readerThread?.interrupt()
        readerThread = null
    }
}
