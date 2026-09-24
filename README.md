# codeit — `com.farou9.codeit`

Standalone Android Linux IDE. Embeds a PRoot Linux environment (Ubuntu / Alpine / Debian) without requiring Termux to be installed. Downloads rootfs from Termux proot-distro mirrors on first launch and runs it under PRoot inside a PTY kept alive by a Foreground Service.

## Package
`com.farou9.codeit` · `targetSdk 34` · `minSdk 24` · `arm64-v8a` only

## W^X Compliance (Android 10+)
All native executables live in `android/app/src/main/jniLibs/arm64-v8a/` as `lib*.so` so the OS extracts them to `nativeLibraryDir` (the only executable location). `libpty.so` is built by CMake via `externalNativeBuild` — do not place it manually.

| Binary | jniLibs path | Runtime |
|---|---|---|
| proot | `libproot.so` | `<nativeLibraryDir>/libproot.so` |
| bash / busybox | `libbash.so` | `<nativeLibraryDir>/libbash.so` |
| bsdtar | `libtar.so` | `<nativeLibraryDir>/libtar.so` |
| JNI bridge | *(built by CMake)* | `<nativeLibraryDir>/libpty.so` |

**Fallback:** if a binary is missing from `nativeLibraryDir`, `PtyBridge.resolveBinary()` copies it from Flutter assets `assets/bin/<name>` → `filesDir/bin/<name>` and `setExecutable(true)`. On Android 10+ W^X may still block exec from `filesDir` — keep jniLibs populated as the primary path.

`PtyBridge.kt` resolves paths via `applicationInfo.nativeLibraryDir`, then the assets fallback.

## Project Structure

```
codeit/
├── android/
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml          # extractNativeLibs=true, ForegroundService
│   │   ├── kotlin/com/farou9/codeit/
│   │   │   ├── MainActivity.kt          # MethodChannel + EventChannel bridge
│   │   │   ├── PtyBridge.kt             # Kotlin wrapper for JNI PTY
│   │   │   └── PtyService.kt            # Foreground Service (Phantom Killer guard)
│   │   ├── jni/
│   │   │   ├── pty_bridge.c             # openpty + fork + proot exec
│   │   │   └── CMakeLists.txt           # wired via externalNativeBuild → libpty.so
│   │   └── jniLibs/arm64-v8a/           # libproot.so, libbash.so, libtar.so (libpty built by CMake)
│   └── build.gradle / settings.gradle
├── lib/
│   ├── main.dart                        # RootRouter (Setup vs Terminal)
│   ├── services/
│   │   ├── proot_engine.dart            # Dart ↔ Native IPC
│   │   ├── rootfs_installer.dart        # Download + extract with progress
│   │   └── archive_extractor.dart       # Dart archive fallback
│   ├── screens/
│   │   ├── setup_screen.dart
│   │   └── terminal_screen.dart
│   ├── widgets/extra_keys_row.dart
│   └── utils/constants.dart
├── assets/bin/                          # Fallback copies of libproot.so etc. (PtyBridge.resolveBinary)
└── pubspec.yaml
```

## Setup Flow
1. `RootRouter` checks `isInstalled()` (SharedPreferences + native rootfs check).
2. If not installed → `SetupScreen`: pick distro → download from mirrors → extract via `libtar.so` (or Dart fallback) → post-configure → set `is_installed=true` → navigate to `TerminalScreen`.
3. `TerminalScreen` starts `PtyBridge` (which starts `PtyService` foreground notification) and attaches `xterm.dart` to the PTY EventChannel. Resize events send `SIGWINCH`.

## Prerequisites — Populating jniLibs

**One command** (downloads static Alpine `proot` + `busybox` into both
`jniLibs/arm64-v8a/` and `assets/bin/`):

```bash
bash scripts/fetch-native-binaries.sh
```

Defaults:

| File | Source |
|---|---|
| `libproot.so` | Alpine `proot-static-5.4.0-r2.aarch64` (static ELF) |
| `libbash.so` | Alpine `busybox-static-1.38.0-r7.aarch64` (static ELF) |
| `libtar.so` | *optional* — Dart `ArchiveExtractor` is the fallback |
| `libpty.so` | built by CMake via `externalNativeBuild` — automatic |

Manual equivalent:

```bash
curl -fL -o /tmp/p.apk https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/proot-static-5.4.0-r2.apk
tar -xzf /tmp/p.apk -C /tmp
cp /tmp/usr/bin/proot.static android/app/src/main/jniLibs/arm64-v8a/libproot.so
cp /tmp/usr/bin/proot.static assets/bin/libproot.so
chmod 755 android/app/src/main/jniLibs/arm64-v8a/libproot.so assets/bin/libproot.so
# Repeat for busybox-static → libbash.so
```

Verify after build:

```bash
unzip -lv build/app/outputs/flutter-apk/app-release.apk | grep 'lib/arm64-v8a/'
# Must list: libproot.so  libbash.so  libpty.so  libflutter.so  libapp.so
```

## Initialization
```bash
flutter create --org com.farou9 --project-name codeit codeit
# Then overlay the files from this repository on top of the generated project.
```

**Do NOT run `flutter build`** in this environment — focus on code generation and verification via `flutter analyze` / `dart analyze`.

## Permissions
`INTERNET`, `ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `WAKE_LOCK`, `POST_NOTIFICATIONS`.

## License
MIT
