# Binaries (fallback copy target)

Primary location is `android/app/src/main/jniLibs/arm64-v8a/`.

If a binary is **missing** from `nativeLibraryDir` at runtime, the Kotlin
bridge (`PtyBridge.resolveBinary`) copies it from here:

| Asset path in APK              | Runtime destination            |
|--------------------------------|--------------------------------|
| `assets/flutter_assets/bin/libproot.so` | `filesDir/bin/libproot.so` |
| `assets/flutter_assets/bin/libbash.so`  | `filesDir/bin/libbash.so`  |
| `assets/flutter_assets/bin/libtar.so`   | `filesDir/bin/libtar.so`   |

Place the same `aarch64` static binaries here (renamed `lib*.so`) as a
belt-and-suspenders fallback when `jniLibs` packaging is skipped or the
device fails to extract to `nativeLibraryDir`.

See `android/app/src/main/jniLibs/arm64-v8a/README.md` for source URLs.
