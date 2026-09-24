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
 * Binary resolution order (W^X first, assets fallback second):
 *  1. applicationInfo.nativeLibraryDir/<name>   (extracted from APK jniLibs)
 *  2. filesDir/bin/<name>                       (already copied earlier)
 *  3. Copy from Flutter assets flutter_assets/bin/<name> → filesDir/bin/<name>
 *
 * The PTY is managed in native code (pty_bridge.c -> libpty.so, built via CMake).
 *
 * Flow:
 *  Dart --MethodChannel--> PtyBridge.start() --> nativePtyStart()
 *  native thread reads from PTY master fd --> callback --> EventChannel --> xterm.dart
 *  Dart writes --> PtyBridge.write() --> nativePtyWrite()
 */
class PtyBridge(private val context: Context) {

    companion object {
        private const val TAG = "PtyBridge"
        init {
            try {
                System.loadLibrary("pty")
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load libpty.so — ensure externalNativeBuild/CMake is wired in build.gradle", e)
            }
        }
    }

    /** Called on a background thread with raw bytes from the PTY master. */
    var onBytes: ((ByteArray) -> Unit)? = null

    private val running = AtomicBoolean(false)
    private var readerThread: Thread? = null

    /** Last failure message — set by [start], read by MainActivity for PTY_START_FAILED. */
    @Volatile
    var lastError: String = ""
        private set

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
    private external fun nativePtyGetLastError(): String

    /**
     * Resolve [name] (e.g. "libproot.so") to an executable absolute path.
     *
     * Order:
     *  1. nativeLibraryDir/name  (preferred — W^X compliant)
     *  2. filesDir/bin/name      (already-copied fallback)
     *  3. assets flutter_assets/bin/name → copy to filesDir/bin/name
     *
     * Returns null if the binary cannot be found or made executable.
     */
    fun resolveBinary(name: String, nativeLibDir: String, filesDir: String): String? {
        // ---- 1. Primary: nativeLibraryDir ----
        val primary = File(nativeLibDir, name)
        if (primary.exists()) {
            if (!primary.canExecute()) {
                Log.w(TAG, "$name not +x at $primary — setExecutable(true)")
                primary.setExecutable(true, false)
            }
            if (primary.canExecute()) {
                Log.i(TAG, "$name resolved (nativeLibraryDir): $primary")
                return primary.absolutePath
            }
            Log.w(TAG, "$name exists at $primary but setExecutable failed — trying fallback")
        } else {
            val listing = File(nativeLibDir).listFiles()
                ?.joinToString { f -> f.name } ?: "(empty or unreadable)"
            Log.w(TAG, "$name missing in nativeLibraryDir ($nativeLibDir). Contents: $listing")
        }

        // ---- 2. Already-copied fallback in filesDir/bin ----
        val fallbackDir = File(filesDir, "bin")
        if (!fallbackDir.exists()) fallbackDir.mkdirs()
        val fallback = File(fallbackDir, name)
        if (fallback.exists()) {
            if (!fallback.canExecute()) fallback.setExecutable(true, false)
            if (fallback.canExecute()) {
                Log.i(TAG, "$name resolved (filesDir/bin): $fallback")
                return fallback.absolutePath
            }
        }

        // ---- 3. Copy from Flutter assets → filesDir/bin ----
        // Flutter packages pubspec assets under "flutter_assets/" inside the APK.
        val assetPath = "flutter_assets/bin/$name"
        try {
            context.assets.open(assetPath).use { input ->
                fallback.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            fallback.setExecutable(true, false)
            if (fallback.canExecute()) {
                Log.i(TAG, "$name copied from assets ($assetPath) → $fallback")
                return fallback.absolutePath
            }
            Log.e(TAG, "$name copied to $fallback but setExecutable(true) failed")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to copy $name from assets ($assetPath): $e")
        }

        return null
    }

    /**
     * Start the PRoot session.
     *
     * Resolves libproot.so / libbash.so via [resolveBinary] (nativeLibraryDir
     * first, Flutter assets → filesDir/bin fallback). The proot invocation is
     * built in native code (pty_bridge.c):
     *   libproot.so -r <rootfs> -0 -b /dev -b /proc -b /sys -w /root <shell>
     *
     * <shell> is /bin/bash if present in rootfs, else /bin/sh — exec'd
     * DIRECTLY (no /usr/bin/env wrapper). PATH/HOME/TERM/LANG are set on the
     * child via setenv() before execl so proot and the guest shell inherit them.
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

        lastError = ""

        // ---- Resolve binaries (nativeLibraryDir → assets fallback) ----
        val prootPath = resolveBinary("libproot.so", nativeLibDir, filesDir)
        if (prootPath == null) {
            lastError = "libproot.so not found — missing from nativeLibraryDir AND assets/bin. " +
                "Place it in android/app/src/main/jniLibs/arm64-v8a/ or assets/bin/."
            Log.e(TAG, lastError)
            return false
        }

        // libbash.so is optional — C code falls back to /bin/sh, /bin/busybox, /system/bin/sh
        val bashPath = resolveBinary("libbash.so", nativeLibDir, filesDir)
            ?: "$nativeLibDir/libbash.so"
        Log.i(TAG, "binaries: proot=$prootPath bash=$bashPath")

        // Shell selection mirrors pty_bridge.c detect_shell():
        // prefer /bin/bash if present in rootfs, else /bin/sh
        val shellInGuest = when {
            File(rootfsPath, "bin/bash").exists() -> "/bin/bash"
            File(rootfsPath, "bin/sh").exists() -> "/bin/sh"
            else -> "/bin/sh"
        }
        Log.i(TAG, "shell in guest: $shellInGuest")

        // ---- Verify rootfs ----
        val rootfsFile = File(rootfsPath)
        if (!rootfsFile.exists() || !rootfsFile.isDirectory) {
            lastError = "rootfs missing or not a directory at $rootfsPath — run SetupScreen first"
            Log.e(TAG, lastError)
            return false
        }
        Log.i(TAG, "rootfs OK: $rootfsPath")

        Log.i(TAG, "Starting PTY: proot=$prootPath bash=$bashPath rootfs=$rootfsPath cols=$cols rows=$rows")

        val fd = try {
            nativePtyStart(
                prootPath = prootPath,
                bashPath = bashPath,
                rootfsPath = rootfsPath,
                filesDir = filesDir,
                nativeLibDir = nativeLibDir,
                cols = cols,
                rows = rows,
            )
        } catch (e: Throwable) {
            lastError = "nativePtyStart threw: ${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, lastError, e)
            return false
        }

        if (fd < 0) {
            val nativeMsg = try { nativePtyGetLastError() } catch (_: Throwable) { "" }
            lastError = if (nativeMsg.isNotEmpty()) {
                "nativePtyStart failed (fd=$fd): $nativeMsg"
            } else {
                "nativePtyStart failed (fd=$fd) — see logcat tag PtyBridge-JNI for errno/exit detail"
            }
            Log.e(TAG, lastError)
            return false
        }

        running.set(true)
        startReaderLoop()
        Log.i(TAG, "PTY started, fd=$fd pid=${try { nativePtyGetFd() } catch (_: Throwable) { -1 }}")
        return true
    }

    private fun startReaderLoop() {
        readerThread = thread(name = "pty-reader", isDaemon = true) {
            val buf = ByteArray(8192)
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
