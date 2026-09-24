import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';

/// PRootEngine — Dart-side bridge to the native PTY/PRoot layer.
///
/// Responsibilities:
///  • Resolve W^X-compliant binary paths via MethodChannel (nativeLibraryDir)
///  • Manage PTY lifecycle: start / write / resize / kill
///  • Expose PTY output as a broadcast Stream<Uint8List> for xterm.dart
///  • Installation state (is_installed) via SharedPreferences
///
/// All exec paths point to nativeLibraryDir — never filesDir.
class PRootEngine {
  PRootEngine._();

  static final PRootEngine instance = PRootEngine._();

  static const MethodChannel _method = MethodChannel(AppConstants.methodChannel);
  static const EventChannel _event = EventChannel(AppConstants.eventChannel);

  StreamSubscription? _eventSub;
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>.broadcast();

  /// Broadcast stream of raw PTY bytes (UTF-8 / ANSI escape sequences)
  Stream<Uint8List> get output => _outputController.stream;

  bool _running = false;
  bool get isRunning => _running;

  String? _nativeLibDir;
  String? _filesDir;

  String get nativeLibDir => _nativeLibDir ?? '';
  String get filesDir => _filesDir ?? '';

  /// Absolute path to the extracted rootfs (inside filesDir — scoped storage)
  String get rootfsPath =>
      _filesDir != null ? '$_filesDir/rootfs' : '';

  /// Fallback path only — prefer [resolveBinary] for the real executable path
  /// (nativeLibraryDir first, assets → filesDir/bin second).
  String get prootPath => '$_nativeLibDir/libproot.so';
  String get bashPath => '$_nativeLibDir/libbash.so';
  String get tarPath => '$_nativeLibDir/libtar.so';

  /// Resolve an executable (e.g. 'libproot.so', 'libtar.so') to an absolute path.
  ///
  /// Native side tries nativeLibraryDir first (W^X compliant), then copies
  /// from Flutter assets `assets/bin/<name>` → `filesDir/bin/<name>` if missing.
  Future<String> resolveBinary(String name) async {
    if (_nativeLibDir == null || _filesDir == null) await init();
    try {
      final path = await _method.invokeMethod<String>('resolveBinary', name);
      if (path != null && path.isNotEmpty) return path;
    } catch (e) {
      debugPrint('[PRootEngine] resolveBinary($name) error: $e');
    }
    // Last-ditch sync fallback (no assets copy — just nativeLibraryDir)
    return '$_nativeLibDir/$name';
  }

  // ---------------------------------------------------------------------------
  // Init — call once at app startup
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    try {
      _nativeLibDir = await _method.invokeMethod<String>('getNativeLibDir');
      _filesDir = await _method.invokeMethod<String>('getFilesDir');
      debugPrint('[PRootEngine] nativeLibDir=$_nativeLibDir filesDir=$_filesDir');
      _attachEventChannel();
    } catch (e, st) {
      debugPrint('[PRootEngine] init failed: $e\n$st');
    }
  }

  void _attachEventChannel() {
    _eventSub?.cancel();
    _eventSub = _event.receiveBroadcastStream().listen(
      (dynamic data) {
        if (data is Uint8List) {
          _outputController.add(data);
        } else if (data is List<int>) {
          _outputController.add(Uint8List.fromList(data));
        }
      },
      onError: (e) => debugPrint('[PRootEngine] EventChannel error: $e'),
      onDone: () => debugPrint('[PRootEngine] EventChannel done'),
    );
  }

  // ---------------------------------------------------------------------------
  // Installation state
  // ---------------------------------------------------------------------------

  /// Checks both SharedPreferences flag and actual filesystem presence via native call.
  Future<bool> isInstalled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final flag = prefs.getBool(AppConstants.keyIsInstalled) ?? false;
      // Verify via native (checks rootfs/bin existence)
      final nativeCheck =
          await _method.invokeMethod<bool>('isInstalled') ?? false;
      // If native says installed but flag missing, repair flag
      if (nativeCheck && !flag) {
        await prefs.setBool(AppConstants.keyIsInstalled, true);
        return true;
      }
      return flag && nativeCheck;
    } catch (e) {
      debugPrint('[PRootEngine] isInstalled error: $e');
      return false;
    }
  }

  Future<void> setInstalled(bool value, {String? distroId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyIsInstalled, value);
    if (distroId != null) {
      await prefs.setString(AppConstants.keyInstalledDistro, distroId);
    }
  }

  Future<String?> getInstalledDistro() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.keyInstalledDistro);
  }

  // ---------------------------------------------------------------------------
  // PTY lifecycle
  // ---------------------------------------------------------------------------

  /// Start the PRoot PTY session.
  /// [cols]/[rows] should match the current xterm viewport.
  Future<bool> start({required int cols, required int rows}) async {
    if (_filesDir == null || _nativeLibDir == null) {
      await init();
    }
    if (!await isInstalled()) {
      throw StateError('rootfs not installed — run SetupScreen first');
    }
    try {
      final ok = await _method.invokeMethod<bool>('startPty', {
        'cols': cols,
        'rows': rows,
        'rootfsPath': rootfsPath,
      });
      _running = ok ?? false;
      debugPrint('[PRootEngine] start cols=$cols rows=$rows ok=$_running');
      return _running;
    } catch (e, st) {
      debugPrint('[PRootEngine] start failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> write(Uint8List data) async {
    if (!_running) return;
    try {
      await _method.invokeMethod('write', data);
    } catch (e) {
      debugPrint('[PRootEngine] write error: $e');
    }
  }

  /// Convenience: write a UTF-8 string
  Future<void> writeString(String s) async {
    await write(Uint8List.fromList(s.codeUnits));
  }

  Future<void> resize(int cols, int rows) async {
    if (!_running) return;
    try {
      await _method.invokeMethod('resize', {'cols': cols, 'rows': rows});
    } catch (e) {
      debugPrint('[PRootEngine] resize error: $e');
    }
  }

  Future<void> kill() async {
    _running = false;
    try {
      await _method.invokeMethod('kill');
    } catch (e) {
      debugPrint('[PRootEngine] kill error: $e');
    }
  }

  void dispose() {
    _eventSub?.cancel();
    _outputController.close();
  }
}
