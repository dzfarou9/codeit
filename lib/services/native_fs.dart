import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../utils/constants.dart';

/// NativeFs — Dart bridge to NDK symlink()/chmod() syscalls via MethodChannel.
///
/// Dart's `archive` package cannot reliably create POSIX symlinks on Android,
/// and `Process.run('chmod')` often fails (no chmod binary / W^X). These
/// helpers call the real system calls through `libpty.so` JNI so UsrMerge
/// layouts (`/bin` -> `/usr/bin`) and executable bits survive extraction for
/// Ubuntu, Debian, and Alpine.
class NativeFs {
  NativeFs._();

  static const MethodChannel _ch = MethodChannel(AppConstants.methodChannel);

  /// Create a POSIX symlink at [path] → [target].
  /// Returns true on success (or if an existing link already points at target).
  static Future<bool> symlink(String target, String path) async {
    try {
      final ok = await _ch.invokeMethod<bool>('nativeSymlink', {
        'target': target,
        'path': path,
      });
      return ok == true;
    } catch (e) {
      debugPrint('[NativeFs] symlink($target -> $path) error: $e');
      return false;
    }
  }

  /// chmod(path, mode) — mode is POSIX (e.g. 0755 = 493).
  static Future<bool> chmod(String path, int mode) async {
    try {
      final ok = await _ch.invokeMethod<bool>('nativeChmod', {
        'path': path,
        'mode': mode,
      });
      return ok == true;
    } catch (e) {
      debugPrint('[NativeFs] chmod($path, ${mode.toRadixString(8)}) error: $e');
      return false;
    }
  }

  /// Recursively chmod a directory tree (does not follow symlinked subtrees).
  /// Returns number of entries updated, or -1 on failure.
  static Future<int> chmodTree(String path, int mode) async {
    try {
      final n = await _ch.invokeMethod<int>('nativeChmodTree', {
        'path': path,
        'mode': mode,
      });
      return n ?? -1;
    } catch (e) {
      debugPrint('[NativeFs] chmodTree($path) error: $e');
      return -1;
    }
  }

  /// readlink(path) → target, or null if not a symlink / error.
  static Future<String?> readlink(String path) async {
    try {
      return await _ch.invokeMethod<String>('nativeReadlink', {'path': path});
    } catch (_) {
      return null;
    }
  }

  /// True if path is a symbolic link (lstat).
  static Future<bool> isSymlink(String path) async {
    try {
      return await _ch.invokeMethod<bool>('nativeIsSymlink', {'path': path}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// True if path exists (follows symlinks — dangling link = false).
  static Future<bool> exists(String path) async {
    try {
      return await _ch.invokeMethod<bool>('nativeExists', {'path': path}) ==
          true;
    } catch (_) {
      return false;
    }
  }
}
