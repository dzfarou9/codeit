/**
 * pty_bridge.c — JNI PTY bridge for codeit (com.farou9.codeit)
 *
 * Creates a pseudo-terminal (PTY) and spawns proot+bash inside it.
 * All binaries are resolved from nativeLibraryDir (W^X compliant).
 *
 * Build with NDK:
 *   ndk-build  or  CMake (see CMakeLists.txt)
 * Output: libpty.so -> jniLibs/arm64-v8a/libpty.so
 *
 * PRoot invocation:
 *   <nativeLibDir>/libproot.so \
 *     -r <rootfs> -0 \
 *     -b /dev -b /proc -b /sys \
 *     -b /sdcard/Download:/mnt/download \
 *     -b <filesDir>:/host \
 *     -w /root \
 *     /bin/bash --login
 *
 * If proot is unavailable (test builds), falls back to libbash.so directly.
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
#include <termios.h>
#include <pty.h>          // openpty()
#include <sys/types.h>

#define LOG_TAG "PtyBridge-JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

// Global state — one PTY session at a time (single terminal)
static int g_masterFd = -1;
static int g_slaveFd  = -1;
static pid_t g_childPid = -1;

// Forward
static void set_winsize(int fd, int cols, int rows);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static int file_exists(const char *path) {
    return access(path, X_OK) == 0;
}

static void set_winsize(int fd, int cols, int rows) {
    struct winsize ws;
    ws.ws_col = (unsigned short) cols;
    ws.ws_row = (unsigned short) rows;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ioctl(fd, TIOCSWINSZ, &ws);
}

// ---------------------------------------------------------------------------
// JNI: nativePtyStart
// ---------------------------------------------------------------------------
// Signature: (Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;II)I

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyStart(
        JNIEnv *env, jobject thiz,
        jstring jProotPath, jstring jBashPath, jstring jRootfsPath,
        jstring jFilesDir, jstring jNativeLibDir,
        jint cols, jint rows) {

    const char *prootPath   = (*env)->GetStringUTFChars(env, jProotPath, NULL);
    const char *bashPath    = (*env)->GetStringUTFChars(env, jBashPath, NULL);
    const char *rootfsPath  = (*env)->GetStringUTFChars(env, jRootfsPath, NULL);
    const char *filesDir    = (*env)->GetStringUTFChars(env, jFilesDir, NULL);
    const char *nativeLibDir= (*env)->GetStringUTFChars(env, jNativeLibDir, NULL);

    LOGI("nativePtyStart proot=%s rootfs=%s cols=%d rows=%d", prootPath, rootfsPath, cols, rows);

    // Clean previous session
    if (g_childPid > 0) {
        LOGI("Killing previous child pid=%d", g_childPid);
        kill(g_childPid, SIGKILL);
        waitpid(g_childPid, NULL, 0);
        g_childPid = -1;
    }
    if (g_masterFd >= 0) { close(g_masterFd); g_masterFd = -1; }
    if (g_slaveFd  >= 0) { close(g_slaveFd);  g_slaveFd  = -1; }

    struct winsize ws;
    ws.ws_col = (unsigned short) cols;
    ws.ws_row = (unsigned short) rows;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    int masterFd = -1, slaveFd = -1;
    if (openpty(&masterFd, &slaveFd, NULL, NULL, &ws) != 0) {
        LOGE("openpty failed: %s", strerror(errno));
        goto fail;
    }

    // Make master non-blocking so Java reader can poll without blocking forever
    int flags = fcntl(masterFd, F_GETFL, 0);
    fcntl(masterFd, F_SETFL, flags | O_NONBLOCK);

    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork failed: %s", strerror(errno));
        close(masterFd); close(slaveFd);
        goto fail;
    }

    if (pid == 0) {
        // ---- Child ----
        close(masterFd);

        // Become session leader and attach slave as controlling terminal
        setsid();
        ioctl(slaveFd, TIOCSCTTY, 0);

        dup2(slaveFd, STDIN_FILENO);
        dup2(slaveFd, STDOUT_FILENO);
        dup2(slaveFd, STDERR_FILENO);
        if (slaveFd > 2) close(slaveFd);

        // Environment
        setenv("TERM", "xterm-256color", 1);
        setenv("HOME", "/root", 1);
        setenv("USER", "root", 1);
        setenv("SHELL", "/bin/bash", 1);
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
        setenv("ANDROID_FILES_DIR", filesDir, 1);
        // Ensure proot can find linker etc. inside rootfs
        // Also expose native lib dir if needed
        // Build LD_LIBRARY_PATH if needed (usually not for proot static)

        int useProot = file_exists(prootPath) && file_exists(rootfsPath);
        if (useProot) {
            // Check rootfs has /bin/bash or /bin/sh
            char bashInRootfs[1024];
            snprintf(bashInRootfs, sizeof(bashInRootfs), "%s/bin/bash", rootfsPath);
            const char *shellInRootfs = "/bin/bash";
            if (access(bashInRootfs, X_OK) != 0) {
                shellInRootfs = "/bin/sh";
            }

            // Prepare bind mount for host filesDir and Download
            // /sdcard/Download may not exist on all devices — proot will warn but continue

            LOGI("Child exec: proot -r %s ... %s", rootfsPath, shellInRootfs);

            execl(prootPath, prootPath,
                  "-r", rootfsPath,
                  "-0",
                  "-b", "/dev",
                  "-b", "/proc",
                  "-b", "/sys",
                  "-b", "/sdcard/Download:/mnt/download",
                  // Bind host filesDir for debugging / file exchange
                  // Use dynamic string
                  "-w", "/root",
                  shellInRootfs, "--login",
                  (char *) NULL);

            // If proot exec fails, log and try fallback
            LOGE("execl proot failed: %s", strerror(errno));
            // Fall through to bash fallback
        }

        // Fallback: run bash directly (without PRoot) — useful for testing
        // or when rootfs is not yet fully set up
        LOGI("Fallback exec: %s", bashPath);
        if (file_exists(bashPath)) {
            execl(bashPath, "bash", "--login", (char *) NULL);
            LOGE("execl bash failed: %s", strerror(errno));
        }
        // Last resort: /system/bin/sh
        execl("/system/bin/sh", "sh", (char *) NULL);
        LOGE("All exec attempts failed: %s", strerror(errno));
        _exit(127);
    }

    // ---- Parent ----
    close(slaveFd);
    g_masterFd = masterFd;
    g_slaveFd  = -1; // closed in parent
    g_childPid = pid;

    LOGI("PTY started masterFd=%d childPid=%d", g_masterFd, g_childPid);

    (*env)->ReleaseStringUTFChars(env, jProotPath, prootPath);
    (*env)->ReleaseStringUTFChars(env, jBashPath, bashPath);
    (*env)->ReleaseStringUTFChars(env, jRootfsPath, rootfsPath);
    (*env)->ReleaseStringUTFChars(env, jFilesDir, filesDir);
    (*env)->ReleaseStringUTFChars(env, jNativeLibDir, nativeLibDir);

    return g_masterFd;

fail:
    (*env)->ReleaseStringUTFChars(env, jProotPath, prootPath);
    (*env)->ReleaseStringUTFChars(env, jBashPath, bashPath);
    (*env)->ReleaseStringUTFChars(env, jRootfsPath, rootfsPath);
    (*env)->ReleaseStringUTFChars(env, jFilesDir, filesDir);
    (*env)->ReleaseStringUTFChars(env, jNativeLibDir, nativeLibDir);
    return -1;
}

// ---------------------------------------------------------------------------
// JNI: nativePtyWrite
// ---------------------------------------------------------------------------

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyWrite(JNIEnv *env, jobject thiz,
                                                jbyteArray data, jint length) {
    if (g_masterFd < 0) return -1;
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    ssize_t n = write(g_masterFd, bytes, (size_t) length);
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        LOGE("pty write error: %s", strerror(errno));
        return -1;
    }
    return (jint) n;
}

// ---------------------------------------------------------------------------
// JNI: nativePtyRead — blocking with short timeout via select
// ---------------------------------------------------------------------------

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyRead(JNIEnv *env, jobject thiz,
                                               jbyteArray buffer) {
    if (g_masterFd < 0) return -1;

    jsize cap = (*env)->GetArrayLength(env, buffer);
    jbyte *buf = (*env)->GetByteArrayElements(env, buffer, NULL);

    // Use select with 50ms timeout so we can check child exit periodically
    fd_set rfds;
    struct timeval tv;
    FD_ZERO(&rfds);
    FD_SET(g_masterFd, &rfds);
    tv.tv_sec = 0;
    tv.tv_usec = 50000; // 50ms

    int sel = select(g_masterFd + 1, &rfds, NULL, NULL, &tv);
    if (sel < 0) {
        (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
        if (errno == EINTR) return 0;
        LOGE("select error: %s", strerror(errno));
        return -1;
    }
    if (sel == 0) {
        // Timeout — check if child exited
        if (g_childPid > 0) {
            int status;
            pid_t r = waitpid(g_childPid, &status, WNOHANG);
            if (r == g_childPid) {
                LOGI("Child exited status=%d", status);
                g_childPid = -1;
                (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
                return -1; // EOF signal to Kotlin
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
            // EIO often means child closed slave side
            LOGI("PTY read EIO — child likely exited");
            (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
            return -1;
        }
        LOGE("PTY read error: %s", strerror(errno));
        (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
        return -1;
    }
    if (n == 0) {
        // EOF — check child
        if (g_childPid > 0) {
            int status;
            waitpid(g_childPid, &status, WNOHANG);
            g_childPid = -1;
        }
        (*env)->ReleaseByteArrayElements(env, buffer, buf, JNI_ABORT);
        return -1;
    }

    (*env)->ReleaseByteArrayElements(env, buffer, buf, 0); // copy back
    return (jint) n;
}

// ---------------------------------------------------------------------------
// JNI: nativePtyResize
// ---------------------------------------------------------------------------

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyResize(JNIEnv *env, jobject thiz,
                                                 jint cols, jint rows) {
    if (g_masterFd < 0) return -1;
    set_winsize(g_masterFd, cols, rows);
    // Forward SIGWINCH to child so bash/readline redraws
    if (g_childPid > 0) kill(g_childPid, SIGWINCH);
    LOGD("resize cols=%d rows=%d pid=%d", cols, rows, g_childPid);
    return 0;
}

// ---------------------------------------------------------------------------
// JNI: nativePtyKill
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyKill(JNIEnv *env, jobject thiz) {
    LOGI("nativePtyKill masterFd=%d pid=%d", g_masterFd, g_childPid);
    if (g_childPid > 0) {
        kill(g_childPid, SIGTERM);
        // Give it a moment, then SIGKILL
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
    if (g_slaveFd >= 0) {
        close(g_slaveFd);
        g_slaveFd = -1;
    }
}

// ---------------------------------------------------------------------------
// JNI: nativePtyGetFd
// ---------------------------------------------------------------------------

JNIEXPORT jint JNICALL
Java_com_farou9_codeit_PtyBridge_nativePtyGetFd(JNIEnv *env, jobject thiz) {
    return g_masterFd;
}
