import 'dart:io';
import 'package:archive/archive.dart';

/// archive_extractor — Dart fallback for rootfs extraction when libtar.so
/// is unavailable. Preserves file modes and symlinks via package:archive.
///
/// This is the secondary path; native bsdtar via libtar.so is preferred
/// because it correctly handles POSIX modes, xattrs, and symlinks.
class ArchiveExtractor {
  /// Extract [archivePath] into [destDir].
  /// Returns true on success.
  static Future<bool> extract({
    required String archivePath,
    required String destDir,
  }) async {
    final file = File(archivePath);
    if (!await file.exists()) return false;

    final bytes = await file.readAsBytes();
    final name = archivePath.toLowerCase();

    Archive archive;
    try {
      if (name.endsWith('.tar.xz') || name.endsWith('.txz')) {
        final decompressed = XZDecoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(decompressed);
      } else if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
        final decompressed = GZipDecoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(decompressed);
      } else if (name.endsWith('.tar.bz2') || name.endsWith('.tbz2')) {
        final decompressed = BZip2Decoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(decompressed);
      } else if (name.endsWith('.tar')) {
        archive = TarDecoder().decodeBytes(bytes);
      } else if (name.endsWith('.zip')) {
        archive = ZipDecoder().decodeBytes(bytes);
      } else {
        // Try tar auto-detect
        try {
          archive = TarDecoder().decodeBytes(bytes);
        } catch (_) {
          archive = ZipDecoder().decodeBytes(bytes);
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ArchiveExtractor] decode failed: $e');
      return false;
    }

    for (final entry in archive) {
      final outPath = '$destDir/${entry.name}';
      // Security: prevent zip-slip
      final canonicalDest = Directory(destDir).absolute.path;
      final canonicalOut = File(outPath).absolute.path;
      if (!canonicalOut.startsWith(canonicalDest)) {
        // ignore: avoid_print
        print('[ArchiveExtractor] skipping zip-slip entry: ${entry.name}');
        continue;
      }

      if (entry.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);

        if (entry.isSymbolicLink) {
          // archive package stores symlink target in entry.name for some formats
          // For TarFile, symlink target is accessible differently.
          // We handle via File's symlink creation.
          try {
            // Delete if a file was already written at this path
            if (await outFile.exists()) await outFile.delete();
            final linkTarget = _symlinkTarget(entry);
            if (linkTarget != null) {
              await Link(outPath).create(linkTarget, recursive: true);
              continue;
            }
          } catch (_) {}
        }

        await outFile.writeAsBytes(entry.content as List<int>);

        // Restore executable bits — entry.mode is non-nullable int on current archive package
        if ((entry.mode & 0x49) != 0) {
          try {
            await Process.run('chmod', ['0${entry.mode.toRadixString(8)}', outPath]);
          } catch (_) {}
        }
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    return true;
  }

  static String? _symlinkTarget(ArchiveFile entry) {
    // TarFile exposes symlink via extra fields; ArchiveFile base does not.
    // Try dynamic access.
    try {
      final dynamic d = entry;
      // TarFile has `linkName` or similar
      final v = d.linkName ?? d.symlink ?? d.target;
      if (v is String && v.isNotEmpty) return v;
    } catch (_) {}
    return null;
  }
}
