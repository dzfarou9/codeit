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
 * Environment is passed as an EXPLICIT envp[] to execve() — built in Kotlin
 * as Array<String> of "KEY=VALUE" and converted here. We never pass a null
 * env array (that produced `$PATH=(null)` in proot diagnostics).
 * Required keys: PROOT_TMP_DIR, PATH, HOME, TERM, LANG, SHELL.
 *
 * PROOT_TMP_DIR points at <filesDir>/tmp (created in Kotlin) so proot can
 * create temporary files (else: "can't create temporary file").
 *
 * Shell detection: /bin/bash if present, else /bin/sh. FAILS hard if neither
 * exists under rootfs (dangling default caused:
 *   proot error: '/bin/sh' not found ... $PATH=(null)).
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
#include <limits.h>
#include <dirent.h>

#define LOG_TAG "PtyBridge-JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

/* Global state — one PTY session at a time */
static int g_masterFd = -1;
static int g_childPid  = -1;
static char g_lastError[512] = {0};

/* Forward decls for env helpers used by nativePtyStart */
static void free_envp(char **envp);
static char **build_envp(JNIEnv *env, jobjectArray jEnvp);

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
 * Returns 0 on success; -1 if NO shell exists.
 *
 * Accepts ANY common shell across Ubuntu/Debian/Alpine (UsrMerge-aware):
 *   /bin/sh, /bin/bash, /bin/dash, /bin/busybox,
 *   /usr/bin/sh, /usr/bin/bash, /usr/bin/dash, /usr/bin/busybox
 *
 * NOTE: We intentionally do NOT check /usr/bin/env — proot execs the
 * shell path directly; env is provided via explicit envp[] on execve.
 */
static int detect_shell(const char *rootfsDir, char *out, size_t outLen) {
    /* Prefer interactive shells first; busybox last (Alpine). */
    const char *candidates[] = {
        "/bin/bash",  "/usr/bin/bash",
        "/bin/sh",    "/usr/bin/sh",
        "/bin/dash",  "/usr/bin/dash",
        "/bin/busybox", "/usr/bin/busybox",
        NULL
    };
    char hostPath[1024];

    for (int i = 0; candidates[i] != NULL; i++) {
        snprintf(hostPath, sizeof(hostPath), "%s%s", rootfsDir, candidates[i]);
        if (is_exec(hostPath)) {
            snprintf(out, outLen, "%s", candidates[i]);
            LOGI("detect_shell: found %s (host=%s)", candidates[i], hostPath);
            return 0;
        }
        if (file_exists(hostPath)) {
            snprintf(out, outLen, "%s", candidates[i]);
            LOGW("detect_shell: %s exists but not +x (host=%s) — using anyway",
                 candidates[i], hostPath);
            return 0;
        }
        if (access(hostPath, F_OK) != 0 && errno == ENOENT) {
            char linkBuf[256];
            ssize_t n = readlink(hostPath, linkBuf, sizeof(linkBuf) - 1);
            if (n > 0) {
                linkBuf[n] = '\0';
                LOGW("detect_shell: BROKEN symlink %s → %s", hostPath, linkBuf);
            }
        }
    }

    set_error("No shell in rootfs under %s "
              "(tried /bin/{sh,bash,dash,busybox} and /usr/bin/… — "
              "extraction incomplete; re-run Setup)", rootfsDir);
    return -1;
}

/* Build a NULL-terminated char* envp[] from a Java String[] of "KEY=VALUE".
 * Returns heap array; caller frees with free_envp(). Returns NULL on failure. */
static char **build_envp(JNIEnv *env, jobjectArray jEnvp) {
    if (jEnvp == NULL) {
        LOGE("build_envp: jEnvp is NULL — refusing (would cause $PATH=(null))");
        return NULL;
    }
    jsize n = (*env)->GetArrayLength(env, jEnvp);
    if (n <= 0) {
        LOGE("build_envp: envp length=%d — refusing empty env", (int)n);
        return NULL;
    }
    char **envp = (char **) calloc((size_t)n + 1, sizeof(char *));
    if (envp == NULL) return NULL;

    int count = 0;
    int hasPath = 0, hasTmp = 0;
    for (jsize i = 0; i < n; i++) {
        jstring jstr = (jstring) (*env)->GetObjectArrayElement(env, jEnvp, i);
        if (jstr == NULL) {
            envp[count] = NULL;
            break;
        }
        const char *utf = (*env)->GetStringUTFChars(env, jstr, NULL);
        if (utf != NULL) {
            envp[count] = strdup(utf);
            if (strncmp(utf, "PATH=", 5) == 0) hasPath = 1;
            if (strncmp(utf, "PROOT_TMP_DIR=", 14) == 0) hasTmp = 1;
            (*env)->ReleaseStringUTFChars(env, jstr, utf);
            count++;
        }
        (*env)->DeleteLocalRef(env, jstr);
    }
    envp[count] = NULL;

    if (!hasPath || !hasTmp) {
        LOGE("build_envp: incomplete env (PATH=%d PROOT_TMP_DIR=%d) — aborting",
             hasPath, hasTmp);
        free_envp(envp);
        return NULL;
    }
    LOGI("build_envp: %d entries, PATH and PROOT_TMP_DIR present", count);
    return envp;
}

static void free_envp(char **envp) {
    if (envp == NULL) return;
    for (int i = 0; envp[i] != NULL; i++) free(envp[i]);
    free(envp);
}

/* --------------------------------------------------------------------------
 * JNI: nativePtyStart
 * -------------------------------------------------------------------------- */

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyStart(
        JNIEnv *env, jobject thiz,
        jstring jProotPath, jstring jBashPath, jstring jRootfsPath,
        jstring jFilesDir, jstring jNativeLibDir, jstring jTmpDir,
        jobjectArray jEnvp,
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

    /* ---- Build explicit envp[] BEFORE fork (JNI not safe in child) ---- */
    char **envp = build_envp(env, jEnvp);
    if (envp == NULL) {
        set_error("Failed to build envp from Kotlin Array<String> — "
                  "env must be non-null with PATH and PROOT_TMP_DIR");
        goto fail;
    }

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

    /* ---- Verify ANY shell exists under rootfs BEFORE fork/proot ---- */
    {
        static const char *shellRels[] = {
            "/bin/sh", "/bin/bash", "/bin/dash", "/bin/busybox",
            "/usr/bin/sh", "/usr/bin/bash", "/usr/bin/dash", "/usr/bin/busybox",
            NULL
        };
        int anyShell = 0;
        for (int i = 0; shellRels[i] != NULL; i++) {
            char host[1024];
            snprintf(host, sizeof(host), "%s%s", rootfsPath, shellRels[i]);
            int ex = file_exists(host);
            if (ex) {
                LOGI("shell preflight: %s exists=%d", shellRels[i], ex);
                anyShell = 1;
                break;
            }
        }
        if (!anyShell) {
            set_error("Rootfs extraction incomplete: no shell under %s "
                      "(tried bin/ and usr/bin/ sh|bash|dash|busybox) — "
                      "re-run SetupScreen to re-extract",
                      rootfsPath);
            goto fail;
        }
    }

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

    /* ---- Detect shell inside rootfs (fails hard if missing) ---- */
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
         * Environment: use the EXPLICIT envp[] built from Kotlin's
         * Array<String> ("KEY=VALUE"). Never pass NULL env to execve —
         * that produced `$PATH=(null)` in proot diagnostics.
         * ------------------------------------------------------------------ */
        if (envp == NULL) {
            LOGE("child: envp is NULL — this must not happen (built pre-fork)");
            _exit(126);
        }

        /* Build argv for execve (proot + flags + shell) */
        char *argv_proot[] = {
            (char *) prootPath,
            "-r", (char *) rootfsPath,
            "-0",
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
            "-b", "/dev/urandom:/dev/random",
            "-w", "/root",
            shellInGuest,          /* /bin/bash or /bin/sh — direct, no env */
            NULL
        };
        char *argv_proot_retry[] = {
            (char *) prootPath,
            "-r", (char *) rootfsPath,
            "-0",
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
            "-b", "/dev/urandom:/dev/random",
            shellInGuest,
            NULL
        };

        LOGI("child execve: %s -r %s -0 -b /dev -b /proc -b /sys "
             "-b /dev/urandom:/dev/random -w /root %s",
             prootPath, rootfsPath, shellInGuest);
        {
            int c = 0;
            while (envp[c]) c++;
            LOGI("child envp: %d entries (PATH, PROOT_TMP_DIR, HOME, TERM, ...)", c);
        }

        execve(prootPath, argv_proot, envp);
        LOGE("execve(proot) failed: %s (errno=%d)", strerror(errno), errno);

        /* Retry without -w /root (some proot builds reject unknown flags) */
        execve(prootPath, argv_proot_retry, envp);
        LOGE("execve(proot) retry failed: %s", strerror(errno));

        /* Fallback: run libbash.so directly (no proot — test builds) */
        if (is_exec(bashPath)) {
            char *argv_bash[] = { (char *) bashPath, NULL };
            LOGI("child fallback: execve %s", bashPath);
            execve(bashPath, argv_bash, envp);
            LOGE("execve(bash) failed: %s", strerror(errno));
        }

        /* Last resort: Android system shell */
        {
            char *argv_sh[] = { "sh", NULL };
            LOGI("child last resort: /system/bin/sh");
            execve("/system/bin/sh", argv_sh, envp);
        }
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
    free_envp(envp);

    return g_masterFd;

fail:
    LOGE("nativePtyStart FAILED: %s", g_lastError);
    (*env)->ReleaseStringUTFChars(env, jProotPath, prootPath);
    (*env)->ReleaseStringUTFChars(env, jBashPath, bashPath);
    (*env)->ReleaseStringUTFChars(env, jRootfsPath, rootfsPath);
    (*env)->ReleaseStringUTFChars(env, jFilesDir, filesDir);
    (*env)->ReleaseStringUTFChars(env, jNativeLibDir, nativeLibDir);
    (*env)->ReleaseStringUTFChars(env, jTmpDir, tmpDir);
    free_envp(envp);
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

/* ==========================================================================
 * Native filesystem helpers for rootfs extraction (NDK real syscalls).
 *
 * Dart's archive package cannot create POSIX symlinks reliably on Android
 * and Process.run('chmod') often fails (no chmod binary / W^X). These JNI
 * entry points call the real symlink()/chmod()/readlink() syscalls so
 * UsrMerge layouts (/bin -> /usr/bin) and executable bits survive extraction
 * for Ubuntu, Debian, and Alpine.
 * ========================================================================== */

/** Create a POSIX symlink at [jPath] pointing to [jTarget].
 *  Returns 0 on success, -errno on failure. */
JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativeSymlink(JNIEnv *env, jobject thiz,
                                              jstring jTarget, jstring jPath) {
    if (jTarget == NULL || jPath == NULL) return -EINVAL;
    const char *target = (*env)->GetStringUTFChars(env, jTarget, NULL);
    const char *path   = (*env)->GetStringUTFChars(env, jPath, NULL);
    int rc = symlink(target, path);
    int err = (rc == 0) ? 0 : -errno;
    if (rc != 0) {
        LOGW("symlink(%s -> %s) failed: %s", target, path, strerror(errno));
    } else {
        LOGD("symlink OK: %s -> %s", path, target);
    }
    (*env)->ReleaseStringUTFChars(env, jTarget, target);
    (*env)->ReleaseStringUTFChars(env, jPath, path);
    return err;
}

/** chmod([jPath], [mode]) — mode is POSIX (e.g. 0755 = 493).
 *  Returns 0 on success, -errno on failure. */
JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativeChmod(JNIEnv *env, jobject thiz,
                                            jstring jPath, jint mode) {
    if (jPath == NULL) return -EINVAL;
    const char *path = (*env)->GetStringUTFChars(env, jPath, NULL);
    int rc = chmod(path, (mode_t) mode);
    int err = (rc == 0) ? 0 : -errno;
    if (rc != 0) {
        LOGW("chmod(%s, %o) failed: %s", path, (unsigned) mode, strerror(errno));
    }
    (*env)->ReleaseStringUTFChars(env, jPath, path);
    return err;
}

/** readlink([jPath]) → target string, or null on failure. */
JNIEXPORT jstring JNICALL
Java_com_farou9_codeit_PtyBridge_nativeReadlink(JNIEnv *env, jobject thiz,
                                               jstring jPath) {
    if (jPath == NULL) return NULL;
    const char *path = (*env)->GetStringUTFChars(env, jPath, NULL);
    char buf[4096];
    ssize_t n = readlink(path, buf, sizeof(buf) - 1);
    (*env)->ReleaseStringUTFChars(env, jPath, path);
    if (n < 0) return NULL;
    buf[n] = '\0';
    return (*env)->NewStringUTF(env, buf);
}

/** True if [jPath] is a symbolic link (lstat S_ISLNK). */
JNIEXPORT jboolean JNICALL
Java_com_farou9_codeit_PtyBridge_nativeIsSymlink(JNIEnv *env, jobject thiz,
                                                jstring jPath) {
    if (jPath == NULL) return JNI_FALSE;
    const char *path = (*env)->GetStringUTFChars(env, jPath, NULL);
    struct stat st;
    int rc = lstat(path, &st);
    (*env)->ReleaseStringUTFChars(env, jPath, path);
    return (rc == 0 && S_ISLNK(st.st_mode)) ? JNI_TRUE : JNI_FALSE;
}

/** True if path exists (follows symlinks — dangling link = false). */
JNIEXPORT jboolean JNICALL
Java_com_farou9_codeit_PtyBridge_nativeExists(JNIEnv *env, jobject thiz,
                                             jstring jPath) {
    if (jPath == NULL) return JNI_FALSE;
    const char *path = (*env)->GetStringUTFChars(env, jPath, NULL);
    int ok = (access(path, F_OK) == 0);
    (*env)->ReleaseStringUTFChars(env, jPath, path);
    return ok ? JNI_TRUE : JNI_FALSE;
}

/** Recursively chmod a directory tree.
 *  mode is POSIX (e.g. 0755). Does NOT recurse into symlinked subtrees
 *  (avoids UsrMerge /bin -> /usr/bin double-walk).
 *  Returns number of entries updated, or -1 on root failure. */
static int chmod_tree_c(const char *root, mode_t mode) {
    struct stat st;
    if (lstat(root, &st) != 0) return -1;
    if (S_ISLNK(st.st_mode)) return 0;  /* skip symlink roots */

    int updated = 0;
    if (chmod(root, mode) == 0) updated++;

    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(root);
        if (d != NULL) {
            struct dirent *ent;
            while ((ent = readdir(d)) != NULL) {
                if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
                    continue;
                char child[4096];
                int n = snprintf(child, sizeof(child), "%s/%s", root, ent->d_name);
                if (n <= 0 || n >= (int) sizeof(child)) continue;
                struct stat cst;
                if (lstat(child, &cst) != 0) continue;
                if (S_ISLNK(cst.st_mode)) continue;
                if (S_ISDIR(cst.st_mode)) {
                    int sub = chmod_tree_c(child, mode);
                    if (sub > 0) updated += sub;
                } else {
                    if (chmod(child, mode) == 0) updated++;
                }
            }
            closedir(d);
        }
    }
    return updated;
}

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativeChmodTree(JNIEnv *env, jobject thiz,
                                                jstring jPath, jint mode) {
    if (jPath == NULL) return -1;
    const char *root = (*env)->GetStringUTFChars(env, jPath, NULL);
    int updated = chmod_tree_c(root, (mode_t) mode);
    if (updated < 0) {
        LOGW("chmodTree: failed for %s: %s", root, strerror(errno));
    }
    (*env)->ReleaseStringUTFChars(env, jPath, root);
    return updated;
}
