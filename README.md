# codeit — `com.farou9.codeit`

Standalone Android Linux IDE. Embeds a PRoot Linux environment (Ubuntu / Alpine / Debian) without requiring Termux to be installed. Downloads rootfs from Termux proot-distro mirrors on first launch and runs it under PRoot inside a PTY kept alive by a Foreground Service.

## Package
`com.farou9.codeit` · `targetSdk 34` · `minSdk 24` · `arm64-v8a` only

## W^X Compliance (Android 10+)
All native executables live in `android/app/src/main/jniLibs/arm64-v8a/` as `lib*.so` so the OS extracts them to `nativeLibraryDir` (the only executable location). Never execute from `filesDir`.

| Binary | jniLibs path | Runtime |
|---|---|---|
| proot | `libproot.so` | `<nativeLibraryDir>/libproot.so` |
| bash / busybox | `libbash.so` | `<nativeLibraryDir>/libbash.so` |
| bsdtar | `libtar.so` | `<nativeLibraryDir>/libtar.so` |
| JNI bridge | `libpty.so` | `<nativeLibraryDir>/libpty.so` (built from `pty_bridge.c`) |

`PtyBridge.kt` resolves paths via `applicationInfo.nativeLibraryDir`.

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
│   │   │   ├── CMakeLists.txt
│   │   │   ├── Android.mk / Application.mk
│   │   └── jniLibs/arm64-v8a/           # libproot.so, libbash.so, libtar.so, libpty.so
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
├── assets/rootfs/                       # Optional bundled rootfs (empty by default)
└── pubspec.yaml
```

## Setup Flow
1. `RootRouter` checks `isInstalled()` (SharedPreferences + native rootfs check).
2. If not installed → `SetupScreen`: pick distro → download from mirrors → extract via `libtar.so` (or Dart fallback) → post-configure → set `is_installed=true` → navigate to `TerminalScreen`.
3. `TerminalScreen` starts `PtyBridge` (which starts `PtyService` foreground notification) and attaches `xterm.dart` to the PTY EventChannel. Resize events send `SIGWINCH`.

## Prerequisites — Populating jniLibs

This repo ships `jniLibs/arm64-v8a/README.md` as a placeholder. Before building, populate:

```bash
# Example: fetch static aarch64 proot + busybox + bsdtar
./scripts/fetch-native-binaries.sh   # (create this script per README)

# Or manually:
# 1. Build proot for aarch64-linux-android (static)
# 2. Copy to android/app/src/main/jniLibs/arm64-v8a/libproot.so
# 3. Repeat for bash/busybox -> libbash.so, bsdtar -> libtar.so
# 4. Build libpty.so: cd android && ./gradlew :app:assembleDebug  (CMake builds it)
```

Verify `.so` are uncompressed in the APK:
```bash
unzip -lv build/app/outputs/flutter-apk/app-release.apk | grep 'lib/.*\.so'
# method should be "Stored" (0)
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
