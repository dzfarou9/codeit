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

This repo ships `jniLibs/arm64-v8a/README.md` as a placeholder. Before building, populate:

```bash
# Option A: fetch script (also mirrors into assets/bin/ fallback)
PROOT_URL=... BUSYBOX_URL=... BSDTAR_URL=... ./scripts/fetch-native-binaries.sh

# Option B: manually copy static aarch64 binaries:
#   proot     → android/app/src/main/jniLibs/arm64-v8a/libproot.so
#   bash/busybox → android/app/src/main/jniLibs/arm64-v8a/libbash.so
#   bsdtar    → android/app/src/main/jniLibs/arm64-v8a/libtar.so
#   (optional fallback) same three files → assets/bin/
#
# libpty.so is built automatically by CMake — no manual step.
```

Also copy the same three binaries into `assets/bin/` if you want the Kotlin
assets→`filesDir/bin` fallback to work.

Verify `.so` are packaged in the APK:
```bash
unzip -lv build/app/outputs/flutter-apk/app-release.apk | grep 'lib/arm64-v8a/.*\.so'
# Should list libproot.so, libbash.so, libtar.so, libpty.so, libflutter.so, libapp.so
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
