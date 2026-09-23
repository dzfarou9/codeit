# jniLibs — Native Executables (W^X Compliant)

Android 10+ enforces **W^X** (Write XOR Execute): binaries in `filesDir` /
`cacheDir` cannot be executed. The only executable location is
`nativeLibraryDir` (`/data/app/.../lib/arm64`), where the PackageManager
extracts `.so` files at install time when `extractNativeLibs=true`.

## Required files (rename with `.so` prefix/suffix)

Place the following `aarch64` static binaries here, renamed with `lib*.so`
convention so AGP keeps them uncompressed and the OS extracts them:

| Source binary | Destination in this folder | Runtime path (`nativeLibraryDir`) |
|---------------|----------------------------|-----------------------------------|
| `proot` (PRoot 5.4+) | `libproot.so` | `<nativeLibraryDir>/libproot.so` |
| `bash` (or `busybox`) | `libbash.so` | `<nativeLibraryDir>/libbash.so` |
| `bsdtar` / `tar` | `libtar.so` | `<nativeLibraryDir>/libtar.so` |
| `libpty.so` (JNI bridge, built from `pty_bridge.c`) | `libpty.so` | `<nativeLibraryDir>/libpty.so` |

## Where to obtain binaries

* **proot**: `https://github.com/termux/proot/releases` or cross-compile
  `termux/proot` (`aarch64-linux-android`, static, `-static`).
* **bash / busybox**: Termux `packages.termux.dev` bootstrap or build from
  AOSP NDK `aarch64-linux-android33`.
* **bsdtar**: `libarchive` built for `aarch64-linux-android`.

> NOTE: This directory ships as placeholder in the repo. CI must populate
> it before building. See `scripts/fetch-native-binaries.sh` (optional helper).

## Verification

```bash
# Inside APK — .so must be uncompressed (stored, not deflated):
unzip -lv app-release.apk | grep 'lib/.*\.so'
# Should show method "Stored" (0) and size == compressed size.

# On device:
adb shell run-as com.farou9.codeit ls -l /data/app/.../lib/arm64/
```

`PtyBridge.kt` resolves the absolute path via
`context.applicationInfo.nativeLibraryDir + "/libproot.so"` — never via
`filesDir`.
