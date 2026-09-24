# jniLibs — Native Executables (W^X Compliant)

Android 10+ enforces **W^X** (Write XOR Execute): binaries in `filesDir` /
`cacheDir` cannot be executed. The only executable location is
`nativeLibraryDir` (`/data/app/.../lib/arm64`), where the PackageManager
extracts `.so` files at install time when `extractNativeLibs=true`.

## Required files

Populate this folder (and the fallback `assets/bin/`) with:

| Destination here | Source (default in fetch script) | Runtime path |
|---|---|---|
| `libproot.so` | Alpine `proot-static` aarch64 (static ELF) | `<nativeLibraryDir>/libproot.so` |
| `libbash.so` | Alpine `busybox-static` aarch64 (static ELF) | `<nativeLibraryDir>/libbash.so` |
| `libtar.so` *(optional)* | any aarch64 `tar`/`bsdtar` | `<nativeLibraryDir>/libtar.so` |

`libpty.so` is **built automatically** by CMake via
`externalNativeBuild` in `android/app/build.gradle` — do **not** place it here.

## One-command populate (recommended)

```bash
bash scripts/fetch-native-binaries.sh
```

Defaults (no env vars needed):

| Binary | URL |
|---|---|
| proot | `https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/proot-static-5.4.0-r2.apk` |
| busybox | `https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64/busybox-static-1.38.0-r7.apk` |

Both are **truly static** AArch64 ELFs (no INTERP, no NEEDED) — they run on
Android without `libtalloc` / Termux paths.

Override if needed:

```bash
PROOT_URL=... BUSYBOX_URL=... BSDTAR_URL=... bash scripts/fetch-native-binaries.sh
```

## Manual placement

```bash
# 1) Download Alpine proot-static
curl -fL -o /tmp/proot.apk \
  https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/proot-static-5.4.0-r2.apk
tar -xzf /tmp/proot.apk -C /tmp   # yields /tmp/usr/bin/proot.static

# 2) Rename + place
cp /tmp/usr/bin/proot.static \
   android/app/src/main/jniLibs/arm64-v8a/libproot.so
chmod 755 android/app/src/main/jniLibs/arm64-v8a/libproot.so

# 3) Same file into assets fallback
cp android/app/src/main/jniLibs/arm64-v8a/libproot.so assets/bin/libproot.so

# 4) Repeat for busybox-static → libbash.so
```

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

`pubspec.yaml` (assets fallback for `PtyBridge.resolveBinary`):

```yaml
flutter:
  assets:
    - assets/bin/
```

Together these guarantee every `*.so` under `jniLibs/arm64-v8a/` is packaged
into the APK `lib/arm64-v8a/` and extracted to `nativeLibraryDir` as a real
file (required for `exec()`).

## Verification

```bash
# After flutter build apk:
unzip -lv build/app/outputs/flutter-apk/app-release.apk | grep 'lib/arm64-v8a/'
# Must list: libproot.so  libbash.so  libpty.so  libflutter.so  libapp.so

# On device:
adb logcat -s PtyBridge PtyBridge-JNI MainActivity
# Look for: "libproot.so resolved (nativeLibraryDir): ..."
```

## Fallback path (assets → filesDir/bin)

If a binary is missing from `nativeLibraryDir`, `PtyBridge.resolveBinary()`
copies it from Flutter assets `assets/bin/<name>` → `filesDir/bin/<name>` and
`setExecutable(true)`. On Android 10+ W^X may still block `exec()` from
`filesDir` — the jniLibs path above is the primary, reliable mechanism.
