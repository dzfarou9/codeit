# jniLibs — Native Executables (W^X Compliant)

Android 10+ enforces **W^X** (Write XOR Execute): binaries in `filesDir` /
`cacheDir` cannot be executed. The only executable location is
`nativeLibraryDir` (`/data/app/.../lib/arm64`), where the PackageManager
extracts `.so` files at install time when `extractNativeLibs=true`.

## Required files (rename with `.so` prefix/suffix)

Place the following `aarch64` static binaries here, renamed with `lib*.so`
convention so AGP packages them into the APK `lib/arm64-v8a/` and the OS
extracts them:

| Source binary | Destination in this folder | Runtime path (`nativeLibraryDir`) |
|---------------|----------------------------|-----------------------------------|
| `proot` (PRoot 5.4+) | `libproot.so` | `<nativeLibraryDir>/libproot.so` |
| `bash` (or `busybox`) | `libbash.so` | `<nativeLibraryDir>/libbash.so` |
| `bsdtar` / `tar` | `libtar.so` | `<nativeLibraryDir>/libtar.so` |

`libpty.so` is **built automatically** by CMake via
`externalNativeBuild` in `android/app/build.gradle` (from
`src/main/jni/pty_bridge.c`) — do **not** place it here manually.

## Where to obtain binaries

* **proot**: `https://github.com/termux/proot/releases` or cross-compile
  `termux/proot` (`aarch64-linux-android`, static, `-static`).
* **bash / busybox**: Termux `packages.termux.dev` bootstrap or build from
  AOSP NDK `aarch64-linux-android33`.
* **bsdtar**: `libarchive` built for `aarch64-linux-android`.

Or run:

```bash
PROOT_URL=... BUSYBOX_URL=... BSDTAR_URL=... bash scripts/fetch-native-binaries.sh
```

> This also copies each binary to `assets/bin/` (fallback source used by
> `PtyBridge.resolveBinary` when `nativeLibraryDir` is missing a file).

> NOTE: This directory ships as a README placeholder in the repo. CI or the
> developer must populate it **before** building, otherwise `libproot.so`
> will be absent from the APK.

## How Gradle packages these

`android/app/build.gradle`:

```gradle
sourceSets {
    main {
        jniLibs.srcDirs = ['src/main/jniLibs']   // explicit
    }
}
packaging {
    jniLibs { useLegacyPackaging = true }        // → extractNativeLibs=true
}
```

`AndroidManifest.xml`:

```xml
<application android:extractNativeLibs="true" ...>
```

Together these guarantee every `*.so` under `jniLibs/arm64-v8a/` ends up as a
real extracted file in `nativeLibraryDir` (required for `exec()`).

## Verification

```bash
# Inside APK — .so must be packaged under lib/arm64-v8a/:
unzip -lv app-release.apk | grep 'lib/arm64-v8a/.*\.so'
# Should list libproot.so, libbash.so, libtar.so, libpty.so, libflutter.so, libapp.so

# On device:
adb shell run-as com.farou9.codeit ls -l /data/app/*/com.farou9.codeit*/lib/arm64/
# or check logcat tag PtyBridge for "resolved (nativeLibraryDir): ..."
```

## Fallback path (assets → filesDir/bin)

If a binary is missing from `nativeLibraryDir`, `PtyBridge.resolveBinary()`
copies it from Flutter assets `assets/bin/<name>` → `filesDir/bin/<name>` and
`setExecutable(true)`. On Android 10+ W^X may still block `exec()` from
`filesDir` — the jniLibs path above is the primary, reliable mechanism.
