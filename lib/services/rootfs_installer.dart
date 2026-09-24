import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/constants.dart';
import 'archive_extractor.dart';
import 'proot_engine.dart';

/// Install phases emitted to SetupScreen for progress UI.
enum InstallPhase {
  idle,
  resolving,
  downloading,
  extracting,
  configuring,
  done,
  error,
}

/// Progress event for SetupScreen.
class InstallProgress {
  final InstallPhase phase;
  final String message;
  final double? progress; // 0.0–1.0, null = indeterminate
  final Object? error;

  const InstallProgress({
    required this.phase,
    required this.message,
    this.progress,
    this.error,
  });
}

/// RootfsInstaller — downloads and extracts a Linux rootfs into filesDir/rootfs.
///
/// Download sources: official distro CDNs (Ubuntu cdimage, Alpine CDN, Debian CDN).
/// Extraction: uses native libtar.so (bsdtar) via nativeLibraryDir if available,
/// otherwise falls back to Dart `archive` package. POSIX modes and symlinks are
/// preserved via the native tar path when possible.
///
/// All operations stay inside context.filesDir (Scoped Storage compliant).
class RootfsInstaller {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      followRedirects: true,
      maxRedirects: 5,
      headers: {
        'User-Agent': 'codeit/1.0 (com.farou9.codeit)',
      },
    ),
  );

  final _controller = StreamController<InstallProgress>.broadcast();
  Stream<InstallProgress> get progress => _controller.stream;

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  void _emit(InstallPhase phase, String msg, {double? progress, Object? error}) {
    _controller.add(InstallProgress(
      phase: phase,
      message: msg,
      progress: progress,
      error: error,
    ));
    debugPrint('[RootfsInstaller] $phase — $msg ${progress != null ? "(${(progress * 100).toStringAsFixed(1)}%)" : ""}');
  }

  /// Main entry: download + extract the selected distro.
  Future<bool> install(RootfsDistro distro) async {
    _cancelled = false;
    try {
      _emit(InstallPhase.resolving, 'Resolving ${distro.displayName}…');

      final filesDir = PRootEngine.instance.filesDir.isNotEmpty
          ? PRootEngine.instance.filesDir
          : (await getApplicationDocumentsDirectory()).path;

      // Ensure fresh state
      final rootfsDir = Directory('$filesDir/rootfs');
      final tmpDir = Directory('$filesDir/.tmp_rootfs');
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      await tmpDir.create(recursive: true);

      // ---------- Download ----------
      String? archivePath;
      Object? lastError;

      for (final mirror in distro.mirrors) {
        if (_cancelled) throw const _CancelledException();
        _emit(InstallPhase.downloading, 'Downloading from mirror…\n$mirror',
            progress: 0);
        try {
          archivePath = await _downloadWithProgress(mirror, tmpDir.path);
          if (archivePath != null) break;
        } catch (e) {
          lastError = e;
          debugPrint('[RootfsInstaller] Mirror failed $mirror: $e');
          _emit(InstallPhase.downloading,
              'Mirror failed, trying next…\n$e',
              progress: null);
          await Future.delayed(const Duration(seconds: 1));
        }
      }

      if (archivePath == null) {
        throw Exception(
            'All mirrors failed for ${distro.id}. Last error: $lastError');
      }

      if (_cancelled) throw const _CancelledException();

      // ---------- Extract ----------
      _emit(InstallPhase.extracting, 'Extracting rootfs…', progress: null);

      // Ensure rootfsDir exists / is empty
      if (await rootfsDir.exists()) {
        await rootfsDir.delete(recursive: true);
      }
      await rootfsDir.create(recursive: true);

      final extracted = await _extract(
        archivePath: archivePath,
        destDir: rootfsDir.path,
        archiveType: distro.archiveType,
      );

      if (!extracted) {
        throw Exception('Extraction failed for $archivePath');
      }

      if (_cancelled) throw const _CancelledException();

      // ---------- Verify shell exists before marking installed ----------
      // Absolute-path tar entries and broken symlink extraction used to leave
      // rootfs without /bin/sh, causing:
      //   proot error: '/bin/sh' not found (root=.../rootfs, cwd=/root, $PATH=(null))
      final shellOk = await _verifyShell(rootfsDir.path);
      if (!shellOk) {
        _emit(InstallPhase.extracting,
            'Extraction incomplete — /bin/sh missing. Retrying with Dart extractor…');
        // Force Dart path (native tar may have failed silently on abs paths)
        try {
          await rootfsDir.delete(recursive: true);
        } catch (_) {}
        await rootfsDir.create(recursive: true);
        final retryOk = await ArchiveExtractor.extract(
          archivePath: archivePath,
          destDir: rootfsDir.path,
        );
        if (!retryOk || !await _verifyShell(rootfsDir.path)) {
          final detail = await _describeRootfs(rootfsDir.path);
          throw Exception(
              'Rootfs extraction incomplete: /bin/sh not found under '
              '$rootfsDir. $detail Re-run setup to re-download.');
        }
        _emit(InstallPhase.extracting, 'Retry succeeded — /bin/sh present.');
      }

      // ---------- Post-configure ----------
      _emit(InstallPhase.configuring, 'Initializing permissions…', progress: null);
      await _postConfigure(rootfsDir.path);

      // Final gate — never mark installed without a shell
      if (!await _verifyShell(rootfsDir.path)) {
        throw Exception(
            'Post-configure failed: /bin/sh still missing in $rootfsDir');
      }

      // ---------- Cleanup ----------
      try {
        await File(archivePath).delete();
        await tmpDir.delete(recursive: true);
      } catch (_) {}

      // ---------- Mark installed ----------
      await PRootEngine.instance.setInstalled(true, distroId: distro.id);

      final shPath = File('${rootfsDir.path}/bin/sh');
      final bashPath = File('${rootfsDir.path}/bin/bash');
      debugPrint('[RootfsInstaller] shell check: '
          'bin/sh exists=${shPath.existsSync()} '
          'bin/bash exists=${bashPath.existsSync()}');

      _emit(InstallPhase.done,
          'Setup complete — /bin/sh verified. Launching terminal…',
          progress: 1.0);
      return true;
    } on _CancelledException {
      _emit(InstallPhase.error, 'Installation cancelled');
      return false;
    } catch (e, st) {
      debugPrint('[RootfsInstaller] install error: $e\n$st');
      _emit(InstallPhase.error, 'Setup failed: $e', error: e);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Download helper
  // ---------------------------------------------------------------------------

  Future<String?> _downloadWithProgress(String url, String tmpDir) async {
    final filename = url.split('/').last.split('?').first;
    final savePath = '$tmpDir/$filename';

    await _dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) {
          final p = received / total;
          _emit(
            InstallPhase.downloading,
            'Downloading… ${(received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB',
            progress: p,
          );
        } else {
          _emit(
            InstallPhase.downloading,
            'Downloading… ${(received / 1048576).toStringAsFixed(1)} MB',
            progress: null,
          );
        }
      },
      deleteOnError: true,
    );

    final f = File(savePath);
    if (!await f.exists() || await f.length() == 0) {
      throw Exception('Download produced empty file: $savePath');
    }
    return savePath;
  }

  // ---------------------------------------------------------------------------
  // Extraction — dynamic compression detection + native tar / Dart fallback
  // ---------------------------------------------------------------------------

  /// Detect compression format from file extension and return tar flags.
  /// GNU tar requires explicit -z / -J / -j; bsdtar auto-detects but the
  /// explicit flags are safe for both.
  static List<String> _tarExtractFlags(String archivePath) {
    final lower = archivePath.toLowerCase();
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      return ['-xzpf'];  // gzip
    } else if (lower.endsWith('.tar.xz') || lower.endsWith('.txz')) {
      return ['-xJpf'];  // xz
    } else if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) {
      return ['-xjpf'];  // bzip2
    } else if (lower.endsWith('.tar')) {
      return ['-xpf'];   // plain tar
    }
    // Unknown — let tar auto-detect (bsdtar) or fail loudly
    return ['-xpf'];
  }

  Future<bool> _extract({
    required String archivePath,
    required String destDir,
    required ArchiveType archiveType,
  }) async {
    debugPrint('[RootfsInstaller] extracting $archivePath → $destDir '
        '(type=$archiveType, flags=${_tarExtractFlags(archivePath)})');

    // 1) Try native tar (preserves symlinks / modes correctly)
    final tarOk = await _extractViaNativeTar(archivePath, destDir);
    if (tarOk) return true;

    // 2) Fall back to pure-Dart ArchiveExtractor
    debugPrint('[RootfsInstaller] native tar failed, using Dart ArchiveExtractor');
    try {
      return await ArchiveExtractor.extract(
        archivePath: archivePath,
        destDir: destDir,
      );
    } catch (e, st) {
      debugPrint('[RootfsInstaller] ArchiveExtractor threw: $e\n$st');
      return false;
    }
  }

  Future<bool> _extractViaNativeTar(String archive, String dest) async {
    try {
      // resolveBinary: nativeLibraryDir first, then assets → filesDir/bin fallback
      final tarBin = await PRootEngine.instance.resolveBinary('libtar.so');
      final tarFile = File(tarBin);
      if (!await tarFile.exists()) {
        debugPrint('[RootfsInstaller] libtar.so not found at $tarBin — skipping native extract');
        return false;
      }

      // Pick flags based on compression: -z (gz), -J (xz), -j (bz2)
      final flags = _tarExtractFlags(archive);
      debugPrint('[RootfsInstaller] running: $tarBin $flags $archive -C $dest');

      final result = await Process.run(tarBin, [...flags, archive, '-C', dest]);

      if (result.exitCode == 0) {
        debugPrint('[RootfsInstaller] native tar succeeded');
        return true;
      }

      // Retry with auto-detect (bsdtar style, no compression flag)
      debugPrint('[RootfsInstaller] native tar exit ${result.exitCode}: '
          '${result.stderr} — retrying with auto-detect');
      final retry = await Process.run(tarBin, ['-xpf', archive, '-C', dest]);
      if (retry.exitCode == 0) {
        debugPrint('[RootfsInstaller] native tar auto-detect succeeded');
        return true;
      }

      debugPrint('[RootfsInstaller] native tar retry failed '
          'exit=${retry.exitCode}: ${retry.stderr}');
      return false;
    } catch (e, st) {
      debugPrint('[RootfsInstaller] native tar exception: $e\n$st');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Shell / rootfs verification
  // ---------------------------------------------------------------------------

  /// Returns true if `<rootfs>/bin/sh` or `<rootfs>/bin/bash` exists
  /// (follows symlinks — a dangling symlink does NOT count).
  Future<bool> _verifyShell(String rootfs) async {
    for (final rel in ['bin/sh', 'bin/bash', 'usr/bin/bash', 'bin/dash']) {
      final f = File('$rootfs/$rel');
      try {
        // File.exists() follows symlinks on dart:io — false for broken links.
        if (await f.exists()) {
          debugPrint('[RootfsInstaller] shell OK: $rel → ${f.absolute.path}');
          return true;
        }
        // Distinguish broken symlink from missing for logs
        try {
          final link = Link('$rootfs/$rel');
          if (await link.exists()) {
            final target = await link.target();
            debugPrint(
                '[RootfsInstaller] BROKEN symlink $rel → $target (target missing)');
          }
        } catch (_) {}
      } catch (e) {
        debugPrint('[RootfsInstaller] shell check error for $rel: $e');
      }
    }
    return false;
  }

  /// Best-effort listing for error messages.
  Future<String> _describeRootfs(String rootfs) async {
    try {
      final bin = Directory('$rootfs/bin');
      if (!await bin.exists()) return 'No $rootfs/bin directory.';
      final names = await bin
          .list()
          .map((e) => e.uri.pathSegments.last)
          .take(20)
          .toList();
      return 'bin/ contains: ${names.join(", ")}';
    } catch (e) {
      return 'Cannot list bin/: $e';
    }
  }

  // ---------------------------------------------------------------------------
  // Post-configure: minimal rootfs fixups
  // ---------------------------------------------------------------------------

  Future<void> _postConfigure(String rootfs) async {
    // Ensure essential directories exist
    for (final dir in ['dev', 'proc', 'sys', 'tmp', 'mnt/download', 'host']) {
      await Directory('$rootfs/$dir').create(recursive: true);
    }

    // Ensure /etc/resolv.conf points to a working DNS
    final resolvConf = File('$rootfs/etc/resolv.conf');
    if (!await resolvConf.exists()) {
      await resolvConf.parent.create(recursive: true);
      await resolvConf.writeAsString('nameserver 8.8.8.8\nnameserver 8.8.4.4\n');
    }

    // Ensure /etc/hosts
    final hosts = File('$rootfs/etc/hosts');
    if (!await hosts.exists()) {
      await hosts.writeAsString('127.0.0.1 localhost\n::1 localhost\n');
    }

    // Make /tmp writable
    try {
      await Process.run('chmod', ['1777', '$rootfs/tmp']);
    } catch (_) {}

    // Create a marker so isInstalled() can detect success even without prefs
    await File('$rootfs/.codeit_installed').writeAsString(
        '${DateTime.now().toIso8601String()}\n');
  }

  void dispose() {
    _controller.close();
    _dio.close();
  }
}

class _CancelledException implements Exception {
  const _CancelledException();
  @override
  String toString() => 'Cancelled';
}
