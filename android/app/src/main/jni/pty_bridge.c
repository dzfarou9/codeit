/**
 * pty_bridge.c — JNI PTY bridge for codeit (com.farou9.codeit)
 *
 * Creates a pseudo-terminal (PTY) and spawns proot + shell inside it.
 * All binaries are resolved from nativeLibraryDir (W^X compliant).
 *
 * PRoot invocation (guest paths, resolved inside rootfs by proot):
 *   <nativeLibDir>/libproot.so \
 *     -r <rootfs> -0 \
 *     -b /dev -b /proc -b /sys \
 *     -b /dev/urandom:/dev/random \
 *     -w /root \
 *     <shell>                 # /bin/bash or /bin/sh — DIRECT exec, no env wrapper
 *
 * Environment (PATH/HOME/TERM/LANG/PROOT_TMP_DIR) is set on the child via
 * setenv() BEFORE execl, so proot and the guest shell inherit it. We do NOT
 * use /usr/bin/env — minimal rootfs images often lack it, which caused:
 *   proot error: '/usr/bin/env' not found ... $PATH=(null)
 *
 * PROOT_TMP_DIR points at <filesDir>/tmp (created in Kotlin) so proot can
 * create temporary files (else: "can't create temporary file").
 *
 * Shell detection order inside rootfs (host-visible paths):
 *   1. /bin/bash   (Ubuntu, Debian)
 *   2. /bin/sh     (Alpine, minimal images)
 *   /bin/busybox is intentionally NOT probed — broken symlinks caused
 *   execve("/bin/busybox"): No such file or directory.
 *
 * Every failure path logs errno + context via __android_log_print so
 * logcat tag "PtyBridge-JNI" shows the exact failing call.
 */

#include <jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <termios.h>
#include <pty.h>
#include <sys/types.h>
#include <stdarg.h>

#define LOG_TAG "PtyBridge-JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

/* Global state — one PTY session at a time */
static int g_masterFd = -1;
static int g_childPid  = -1;
static char g_lastError[512] = {0};

static void set_winsize(int fd, int cols, int rows) {
    struct winsize ws;
    ws.ws_col   = (unsigned short) cols;
    ws.ws_row   = (unsigned short) rows;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ioctl(fd, TIOCSWINSZ, &ws);
}

static void set_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_lastError, sizeof(g_lastError), fmt, ap);
    va_end(ap);
    LOGE("%s", g_lastError);
}

/* Check file exists and is executable (F_OK first, then X_OK). */
static int is_exec(const char *path) {
    if (access(path, F_OK) != 0) return 0;
    if (access(path, X_OK) != 0) return 0;
    return 1;
}

static int file_exists(const char *path) {
    return access(path, F_OK) == 0;
}

/**
 * Detect the best shell inside [rootfsDir].
 * Writes the guest path (e.g. "/bin/bash") into [out].
 * Always returns 0 (default "/bin/sh").
 *
 * Candidates: /bin/bash, /bin/sh only. We never probe /bin/busybox —
 * Alpine images often have a broken/missing busybox path which caused:
 *   proot error: execve("/bin/busybox"): No such file or directory
 *
 * NOTE: We intentionally do NOT check /usr/bin/env — proot execs the
 * shell path directly; env is provided via setenv() on the child.
 */
static int detect_shell(const char *rootfsDir, char *out, size_t outLen) {
    const char *candidates[] = { "/bin/bash", "/bin/sh", NULL };
    char hostPath[1024];

    for (int i = 0; candidates[i] != NULL; i++) {
        snprintf(hostPath, sizeof(hostPath), "%s%s", rootfsDir, candidates[i]);
        if (is_exec(hostPath)) {
            snprintf(out, outLen, "%s", candidates[i]);
            LOGI("detect_shell: found %s (host=%s)", candidates[i], hostPath);
            return 0;
        }
        /* Also accept a plain file (not +x yet — proot/chmod may fix later) */
        if (file_exists(hostPath)) {
            snprintf(out, outLen, "%s", candidates[i]);
            LOGW("detect_shell: %s exists but not +x (host=%s) — using anyway",
                 candidates[i], hostPath);
            return 0;
        }
    }

    /* Default: /bin/sh (present in virtually every rootfs) */
    snprintf(out, outLen, "/bin/sh");
    LOGW("detect_shell: no /bin/bash or /bin/sh under %s — defaulting to /bin/sh",
         rootfsDir);
    return 0;
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyStart
 * -------------------------------------------------------------------------- */

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyStart(
        JNIEnv *env, jobject thiz,
        jstring jProotPath, jstring jBashPath, jstring jRootfsPath,
        jstring jFilesDir, jstring jNativeLibDir, jstring jTmpDir,
        jint cols, jint rows) {

    const char *prootPath    = (*env)->GetStringUTFChars(env, jProotPath, NULL);
    const char *bashPath     = (*env)->GetStringUTFChars(env, jBashPath, NULL);
    const char *rootfsPath   = (*env)->GetStringUTFChars(env, jRootfsPath, NULL);
    const char *filesDir     = (*env)->GetStringUTFChars(env, jFilesDir, NULL);
    const char *nativeLibDir = (*env)->GetStringUTFChars(env, jNativeLibDir, NULL);
    const char *tmpDir       = (*env)->GetStringUTFChars(env, jTmpDir, NULL);

    g_lastError[0] = '\0';

    LOGI("=== nativePtyStart begin ===");
    LOGI("  prootPath    = %s", prootPath);
    LOGI("  bashPath     = %s", bashPath);
    LOGI("  rootfsPath   = %s", rootfsPath);
    LOGI("  filesDir     = %s", filesDir);
    LOGI("  nativeLibDir = %s", nativeLibDir);
    LOGI("  tmpDir       = %s", tmpDir);
    LOGI("  cols=%d rows=%d", cols, rows);

    /* ---- Pre-flight binary verification ---- */
    if (!file_exists(prootPath)) {
        set_error("libproot.so MISSING at %s — place it in jniLibs/arm64-v8a/", prootPath);
        goto fail;
    }
    if (!is_exec(prootPath)) {
        LOGW("libproot.so exists but not +x at %s — attempting chmod", prootPath);
        if (chmod(prootPath, 0755) != 0) {
            set_error("libproot.so not executable and chmod failed (%s): %s",
                      prootPath, strerror(errno));
            goto fail;
        }
    }
    LOGI("libproot.so OK: %s", prootPath);

    if (!file_exists(rootfsPath)) {
        set_error("rootfs MISSING at %s — run SetupScreen first", rootfsPath);
        goto fail;
    }
    LOGI("rootfs OK: %s", rootfsPath);

    /* ---- PROOT_TMP_DIR — writable host dir for proot temp files ---- */
    if (tmpDir == NULL || tmpDir[0] == '\0') {
        set_error("PROOT_TMP_DIR empty — pass filesDir/tmp from Kotlin");
        goto fail;
    }
    if (mkdir(tmpDir, 0700) != 0 && errno != EEXIST) {
        set_error("mkdir(%s) for PROOT_TMP_DIR failed: %s", tmpDir, strerror(errno));
        goto fail;
    }
    if (access(tmpDir, W_OK) != 0) {
        set_error("PROOT_TMP_DIR not writable: %s (%s)", tmpDir, strerror(errno));
        goto fail;
    }
    LOGI("PROOT_TMP_DIR OK: %s", tmpDir);

    /* ---- Detect shell inside rootfs ---- */
    char shellInGuest[256];
    if (detect_shell(rootfsPath, shellInGuest, sizeof(shellInGuest)) != 0) {
        goto fail;  /* set_error already called */
    }
    LOGI("shell in guest: %s", shellInGuest);

    /* ---- Kill previous session ---- */
    if (g_childPid > 0) {
        LOGI("Killing previous child pid=%d", g_childPid);
        kill(g_childPid, SIGKILL);
        waitpid(g_childPid, NULL, 0);
        g_childPid = -1;
    }
    if (g_masterFd >= 0) { close(g_masterFd); g_masterFd = -1; }

    /* ---- Open PTY ---- */
    struct winsize ws;
    ws.ws_col   = (unsigned short) cols;
    ws.ws_row   = (unsigned short) rows;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    int masterFd = -1, slaveFd = -1;
    if (openpty(&masterFd, &slaveFd, NULL, NULL, &ws) != 0) {
        set_error("openpty() failed: %s (errno=%d)", strerror(errno), errno);
        goto fail;
    }
    LOGI("openpty OK: master=%d slave=%d", masterFd, slaveFd);

    /* Non-blocking master so reader thread can poll */
    int flags = fcntl(masterFd, F_GETFL, 0);
    fcntl(masterFd, F_SETFL, flags | O_NONBLOCK);

    /* ---- Fork ---- */
    pid_t pid = fork();
    if (pid < 0) {
        set_error("fork() failed: %s (errno=%d)", strerror(errno), errno);
        close(masterFd);
        close(slaveFd);
        goto fail;
    }

    if (pid == 0) {
        /* ===================== CHILD ===================== */
        close(masterFd);

        /* New session + controlling TTY */
        if (setsid() < 0) {
            LOGE("child setsid failed: %s", strerror(errno));
        }
        ioctl(slaveFd, TIOCSCTTY, 0);

        dup2(slaveFd, STDIN_FILENO);
        dup2(slaveFd, STDOUT_FILENO);
        dup2(slaveFd, STDERR_FILENO);
        if (slaveFd > 2) close(slaveFd);

        /* ------------------------------------------------------------------
         * Environment for the child process (proot + guest shell inherit).
         * setenv before execl — NO /usr/bin/env wrapper (minimal rootfs
         * images often lack /usr/bin/env, which caused:
         *   proot error: '/usr/bin/env' not found ... $PATH=(null))
         *
         * PROOT_TMP_DIR is required — without it proot fails:
         *   can't create temporary file: No such file or directory
         * ------------------------------------------------------------------ */
        setenv("HOME",  "/root", 1);
        setenv("PATH",  "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
        setenv("TERM",  "xterm-256color", 1);
        setenv("LANG",  "C.UTF-8", 1);
        setenv("LC_ALL","C.UTF-8", 1);
        setenv("USER",  "root", 1);
        setenv("LOGNAME","root", 1);
        setenv("SHELL", shellInGuest, 1);
        setenv("PROOT_TMP_DIR", tmpDir, 1);
        setenv("TMPDIR", tmpDir, 1);
        if (filesDir) setenv("ANDROID_FILES_DIR", filesDir, 1);

        /* ------------------------------------------------------------------
         * PRoot argument list (matches user spec):
         *   proot -r <rootfs> -0 -b /dev -b /proc -b /sys
         *         -b /dev/urandom:/dev/random -w /root <shell>
         * Shell is chosen by detect_shell(): /bin/bash if present, else /bin/sh.
         * ------------------------------------------------------------------ */
        LOGI("child exec: %s -r %s -0 -b /dev -b /proc -b /sys "
             "-b /dev/urandom:/dev/random -w /root %s",
             prootPath, rootfsPath, shellInGuest);
        LOGI("child env: HOME=/root PATH=... TERM=xterm-256color LANG=C.UTF-8 "
             "PROOT_TMP_DIR=%s SHELL=%s", tmpDir, shellInGuest);

        execl(prootPath, prootPath,
              "-r", rootfsPath,
              "-0",
              "-b", "/dev",
              "-b", "/proc",
              "-b", "/sys",
              "-b", "/dev/urandom:/dev/random",
              "-w", "/root",
              shellInGuest,          /* /bin/bash or /bin/sh — direct, no env */
              (char *) NULL);

        /* execl only returns on failure */
        LOGE("execl(proot) failed: %s (errno=%d)", strerror(errno), errno);

        /* Retry without -w /root (some proot builds reject unknown flags) */
        execl(prootPath, prootPath,
              "-r", rootfsPath,
              "-0",
              "-b", "/dev",
              "-b", "/proc",
              "-b", "/sys",
              "-b", "/dev/urandom:/dev/random",
              shellInGuest,
              (char *) NULL);
        LOGE("execl(proot) retry failed: %s", strerror(errno));

        /* Fallback: run libbash.so directly (no proot — test builds) */
        if (is_exec(bashPath)) {
            LOGI("child fallback: exec %s", bashPath);
            execl(bashPath, bashPath, (char *) NULL);
            LOGE("execl(bash) failed: %s", strerror(errno));
        }

        /* Last resort: Android system shell */
        LOGI("child last resort: /system/bin/sh");
        execl("/system/bin/sh", "sh", (char *) NULL);
        LOGE("ALL exec attempts failed: %s", strerror(errno));
        _exit(127);
    }

    /* ===================== PARENT ===================== */
    close(slaveFd);
    g_masterFd = masterFd;
    g_childPid  = pid;

    LOGI("PTY started: masterFd=%d childPid=%d", g_masterFd, g_childPid);
    LOGI("=== nativePtyStart done (fd=%d) ===", g_masterFd);

    (*env)->ReleaseStringUTFChars(env, jProotPath, prootPath);
    (*env)->ReleaseStringUTFChars(env, jBashPath, bashPath);
    (*env)->ReleaseStringUTFChars(env, jRootfsPath, rootfsPath);
    (*env)->ReleaseStringUTFChars(env, jFilesDir, filesDir);
    (*env)->ReleaseStringUTFChars(env, jNativeLibDir, nativeLibDir);
    (*env)->ReleaseStringUTFChars(env, jTmpDir, tmpDir);

    return g_masterFd;

fail:
    LOGE("nativePtyStart FAILED: %s", g_lastError);
    (*env)->ReleaseStringUTFChars(env, jProotPath, prootPath);
    (*env)->ReleaseStringUTFChars(env, jBashPath, bashPath);
    (*env)->ReleaseStringUTFChars(env, jRootfsPath, rootfsPath);
    (*env)->ReleaseStringUTFChars(env, jFilesDir, filesDir);
    (*env)->ReleaseStringUTFChars(env, jNativeLibDir, nativeLibDir);
    (*env)->ReleaseStringUTFChars(env, jTmpDir, tmpDir);
    return -1;
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyGetLastError — returns the last error string to Kotlin
 * -------------------------------------------------------------------------- */

JNIEXPORT jstring JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyGetLastError(JNIEnv *env, jobject thiz) {
    return (*env)->NewStringUTF(env, g_lastError);
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyWrite
 * -------------------------------------------------------------------------- */

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyWrite(JNIEnv *env, jobject thiz,
                                                jbyteArray data, jint length) {
    if (g_masterFd < 0) return -1;
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    ssize_t n = write(g_masterFd, bytes, (size_t) length);
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        LOGE("pty write error: %s (errno=%d)", strerror(errno), errno);
        return -1;
    }
    return (jint) n;
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyRead — select() with 50ms timeout + child-exit check
 * -------------------------------------------------------------------------- */

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyRead(JNIEnv *env, jobject thiz,
                                               jbyteArray buffer) {
    if (g_masterFd < 0) return -1;

    jsize cap = (*env)->GetArrayLength(env, buffer);
    jbyte *buf = (*env)->GetByteArrayElements(env, buffer, NULL);

    fd_set rfds;
    struct timeval tv;
    FD_ZERO(&rfds);
    FD_SET(g_masterFd, &rfds);
    tv.tv_sec  = 0;
    tv.tv_usec = 50000; /* 50ms */

    int sel = select(g_masterFd + 1, &rfds, NULL, NULL, &tv);
    if (sel < 0) {
        (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
        if (errno == EINTR) return 0;
        LOGE("select error: %s (errno=%d)", strerror(errno), errno);
        return -1;
    }
    if (sel == 0) {
        /* Timeout — poll child exit */
        if (g_childPid > 0) {
            int status;
            pid_t r = waitpid(g_childPid, &status, WNOHANG);
            if (r == g_childPid) {
                int code = WIFEXITED(status) ? WEXITSTATUS(status)
                          : WIFSIGNALED(status) ? -WTERMSIG(status) : status;
                LOGI("child exited: raw=%d code=%d", status, code);
                g_childPid = -1;
                (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
                return -1; /* EOF → Kotlin */
            }
        }
        (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
        return 0;
    }

    ssize_t n = read(g_masterFd, buf, (size_t) cap);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
            return 0;
        }
        if (errno == EIO) {
            LOGI("PTY read EIO — child closed slave side");
            (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
            return -1;
        }
        LOGE("PTY read error: %s (errno=%d)", strerror(errno), errno);
        (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
        return -1;
    }
    if (n == 0) {
        if (g_childPid > 0) {
            int status;
            waitpid(g_childPid, &status, WNOHANG);
            g_childPid = -1;
        }
        (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
        return -1;
    }

    (*env)->ReleaseByteArrayElements(env, buffer, buf, 0);
    return (jint) n;
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyResize — TIOCSWINSZ + SIGWINCH to child
 * -------------------------------------------------------------------------- */

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyResize(JNIEnv *env, jobject thiz,
                                                 jint cols, jint rows) {
    if (g_masterFd < 0) return -1;
    set_winsize(g_masterFd, cols, rows);
    if (g_childPid > 0) kill(g_childPid, SIGWINCH);
    LOGD("resize cols=%d rows=%d pid=%d", cols, rows, g_childPid);
    return 0;
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyKill
 * -------------------------------------------------------------------------- */

JNIEXPORT void JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyKill(JNIEnv *env, jobject thiz) {
    LOGI("nativePtyKill masterFd=%d pid=%d", g_masterFd, g_childPid);
    if (g_childPid > 0) {
        kill(g_childPid, SIGTERM);
        usleep(200000);
        kill(g_childPid, SIGKILL);
        int status;
        waitpid(g_childPid, NULL, 0);
        g_childPid = -1;
    }
    if (g_masterFd >= 0) {
        close(g_masterFd);
        g_masterFd = -1;
    }
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyGetFd
 * -------------------------------------------------------------------------- */

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyGetFd(JNIEnv *env, jobject thiz) {
    return g_masterFd;
}
