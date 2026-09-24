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
        tmpDir: String,
        envp: Array<String>,
        cols: Int,
        rows: Int,
    ): Int  // returns fd or -1

    private external fun nativePtyWrite(data: ByteArray, length: Int): Int
    private external fun nativePtyResize(cols: Int, rows: Int): Int
    private external fun nativePtyKill()
    private external fun nativePtyGetFd(): Int
    private external fun nativePtyGetLastError(): String

    // ---- Native FS helpers (real symlink()/chmod() syscalls — NDK) ----
    // Used by rootfs extraction for POSIX symlinks + executable bits.
    external fun nativeSymlink(target: String, path: String): Int
    external fun nativeChmod(path: String, mode: Int): Int
    external fun nativeReadlink(path: String): String?
    external fun nativeIsSymlink(path: String): Boolean
    external fun nativeExists(path: String): Boolean
    external fun nativeChmodTree(path: String, mode: Int): Int

    /**
     * Create a POSIX symlink via native symlink(2).
     * Returns true on success (or if the link already points at [target]).
     */
    fun symlink(target: String, path: String): Boolean {
        val rc = try {
            nativeSymlink(target, path)
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "nativeSymlink unavailable — falling back to java.nio: $e")
            return _javaSymlink(target, path)
        }
        if (rc == 0) return true
        // EEXIST (-17 on bionic/linux) — check if existing link already correct
        if (rc == -17) {
            val existing = try { nativeReadlink(path) } catch (_: Throwable) { null }
            if (existing == target) return true
            // Replace wrong/stale link
            _deletePath(path)
            val rc2 = try { nativeSymlink(target, path) } catch (_: Throwable) { -1 }
            return rc2 == 0
        }
        Log.w(TAG, "nativeSymlink($target -> $path) rc=$rc — trying java fallback")
        return _javaSymlink(target, path)
    }

    /** chmod via native chmod(2). mode is POSIX (e.g. 0755 = 493). */
    fun chmod(path: String, mode: Int): Boolean {
        return try {
            nativeChmod(path, mode) == 0
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "nativeChmod unavailable: $e")
            false
        }
    }

    /** Recursively chmod a tree (does not follow symlinked subtrees). */
    fun chmodTree(path: String, mode: Int): Int {
        return try {
            nativeChmodTree(path, mode)
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "nativeChmodTree unavailable: $e")
            -1
        }
    }

    fun readlink(path: String): String? {
        return try { nativeReadlink(path) } catch (_: Throwable) { null }
    }

    fun isSymlink(path: String): Boolean {
        return try { nativeIsSymlink(path) } catch (_: Throwable) { false }
    }

    fun exists(path: String): Boolean {
        return try { nativeExists(path) } catch (_: Throwable) { File(path).exists() }
    }

    private fun _javaSymlink(target: String, path: String): Boolean {
        return try {
            _deletePath(path)
            java.nio.file.Files.createSymbolicLink(
                java.nio.file.Paths.get(path),
                java.nio.file.Paths.get(target),
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "java symlink failed for $path -> $target: $e")
            false
        }
    }

    private fun _deletePath(path: String) {
        try {
            val f = File(path)
            if (f.isDirectory && !f.isFile) f.deleteRecursively() else f.delete()
        } catch (_: Exception) {}
        try { java.nio.file.Files.deleteIfExists(java.nio.file.Paths.get(path)) } catch (_: Exception) {}
    }

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
     *   libproot.so -r <rootfs> -0 -b /dev -b /proc -b /sys
     *               -b /dev/urandom:/dev/random -w /root <shell>
     *
     * <shell> is /bin/bash if present in rootfs, else /bin/sh — verified to
     * exist BEFORE invoking proot. Environment is passed as an explicit
     * `envp: Array<String>` ("KEY=VALUE") to execve — never a null env array
     * (null env caused `$PATH=(null)` in proot diagnostics).
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

        // ---- PROOT_TMP_DIR — proot needs a writable host dir for temp files ----
        val tmpDir = File(filesDir, "tmp").apply { mkdirs() }
        if (!tmpDir.isDirectory) {
            lastError = "Cannot create PROOT_TMP_DIR at ${tmpDir.absolutePath}"
            Log.e(TAG, lastError)
            return false
        }
        Log.i(TAG, "PROOT_TMP_DIR=${tmpDir.absolutePath}")

        // ---- Verify ANY shell exists under rootfs BEFORE proot ----
        // UsrMerge: /bin may be a symlink to /usr/bin — File.exists follows it.
        // Accept any of: sh, bash, dash, busybox under bin/ or usr/bin/.
        val rootfsFile = File(rootfsPath)
        if (!rootfsFile.exists() || !rootfsFile.isDirectory) {
            lastError = "rootfs missing or not a directory at $rootfsPath — run SetupScreen first"
            Log.e(TAG, lastError)
            return false
        }
        val shellCandidates = listOf(
            "bin/sh", "bin/bash", "bin/dash", "bin/busybox",
            "usr/bin/sh", "usr/bin/bash", "usr/bin/dash", "usr/bin/busybox",
        )
        val foundShell = shellCandidates.firstOrNull { rel ->
            val f = File(rootfsPath, rel)
            f.exists().also { exists ->
                if (exists) Log.i(TAG, "shell candidate OK: $rel → ${f.absolutePath}")
            }
        }
        // Log broken symlinks for diagnosis
        for (rel in shellCandidates) {
            val f = File(rootfsPath, rel)
            if (!f.exists()) {
                val link = java.nio.file.Paths.get(f.absolutePath)
                try {
                    if (java.nio.file.Files.isSymbolicLink(link)) {
                        val tgt = java.nio.file.Files.readSymbolicLink(link)
                        Log.w(TAG, "BROKEN symlink rootfs/$rel → $tgt")
                    }
                } catch (_: Exception) {}
            }
        }
        if (foundShell == null) {
            val binListing = File(rootfsPath, "bin").listFiles()
                ?.joinToString { f -> f.name + (if (f.isDirectory) "/" else "") }
                ?: "(bin/ missing)"
            val usrBinListing = File(rootfsPath, "usr/bin").listFiles()
                ?.take(15)
                ?.joinToString { f -> f.name }
                ?: "(usr/bin/ missing)"
            lastError = "Rootfs extraction incomplete: no shell found under " +
                "$rootfsPath (bin/: $binListing; usr/bin/: $usrBinListing). " +
                "Re-run SetupScreen to re-extract the rootfs."
            Log.e(TAG, lastError)
            return false
        }
        Log.i(TAG, "rootfs OK: $rootfsPath (shell=$foundShell)")

        // ---- Resolve binaries (nativeLibraryDir → assets fallback) ----
        val prootPath = resolveBinary("libproot.so", nativeLibDir, filesDir)
        if (prootPath == null) {
            lastError = "libproot.so not found — missing from nativeLibraryDir AND assets/bin. " +
                "Place it in android/app/src/main/jniLibs/arm64-v8a/ or assets/bin/."
            Log.e(TAG, lastError)
            return false
        }

        // libbash.so is optional — C code falls back to /bin/sh, /system/bin/sh
        val bashPath = resolveBinary("libbash.so", nativeLibDir, filesDir)
            ?: "$nativeLibDir/libbash.so"
        Log.i(TAG, "binaries: proot=$prootPath bash=$bashPath")

        // Shell selection mirrors pty_bridge.c detect_shell() — any common shell
        val shellInGuest = "/" + foundShell
        Log.i(TAG, "shell in guest: $shellInGuest")

        // ---- Explicit envp for execve — NEVER null ----
        // Converted to C char* envp[] as ["KEY=VALUE", ..., NULL].
        val envMap = mapOf(
            "PROOT_TMP_DIR" to tmpDir.absolutePath,
            "TMPDIR" to tmpDir.absolutePath,
            "HOME" to "/root",
            "PATH" to "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM" to "xterm-256color",
            "LANG" to "en_US.UTF-8",
            "LC_ALL" to "en_US.UTF-8",
            "USER" to "root",
            "LOGNAME" to "root",
            "SHELL" to shellInGuest,
            "ANDROID_FILES_DIR" to filesDir,
        )
        val envp: Array<String> = envMap.map { (k, v) -> "$k=$v" }.toTypedArray()
        // Fail loudly if anything essential is missing
        require(envp.isNotEmpty()) { "envp must not be empty" }
        require(envp.any { it.startsWith("PATH=") }) { "envp missing PATH" }
        require(envp.any { it.startsWith("PROOT_TMP_DIR=") }) { "envp missing PROOT_TMP_DIR" }
        Log.i(TAG, "envp (${envp.size} entries): ${envp.joinToString(" | ")}")

        Log.i(
            TAG,
            "Starting PTY: proot=$prootPath bash=$bashPath rootfs=$rootfsPath " +
                "tmpDir=${tmpDir.absolutePath} shell=$shellInGuest cols=$cols rows=$rows",
        )

        val fd = try {
            nativePtyStart(
                prootPath = prootPath,
                bashPath = bashPath,
                rootfsPath = rootfsPath,
                filesDir = filesDir,
                nativeLibDir = nativeLibDir,
                tmpDir = tmpDir.absolutePath,
                envp = envp,
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
