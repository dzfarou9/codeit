import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// ArchiveExtractor — pure-Dart rootfs extraction fallback used when the
/// native `libtar.so` binary is unavailable.
///
/// Handles `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar`, and `.zip` archives.
/// Symbolic links are recreated via `dart:io` `Link` with parent-directory
/// creation and existing-path cleanup to avoid `Permission Denied` /
/// `FileSystemException` inside `filesDir`.
///
/// Every per-entry failure is caught and logged with the exact file path so
/// a single bad symlink never aborts the whole extraction.
class ArchiveExtractor {
  /// Extract [archivePath] into [destDir].
  ///
  /// Returns `true` if extraction completed (even if some non-fatal entries
  /// were skipped); `false` only on fatal decode/IO failure.
  static Future<bool> extract({
    required String archivePath,
    required String destDir,
  }) async {
    final file = File(archivePath);
    if (!await file.exists()) {
      debugPrint('[ArchiveExtractor] archive not found: $archivePath');
      return false;
    }

    final bytes = await file.readAsBytes();
    final name = archivePath.toLowerCase();

    // ------------------------------------------------------------------
    // 1. Decode — pick decompressor by file extension
    // ------------------------------------------------------------------
    Archive archive;
    try {
      if (name.endsWith('.tar.xz') || name.endsWith('.txz')) {
        debugPrint('[ArchiveExtractor] decoding .tar.xz (XZ + Tar)');
        final decompressed = XZDecoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(decompressed);
      } else if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
        debugPrint('[ArchiveExtractor] decoding .tar.gz (GZip + Tar)');
        final decompressed = GZipDecoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(decompressed);
      } else if (name.endsWith('.tar.bz2') || name.endsWith('.tbz2')) {
        debugPrint('[ArchiveExtractor] decoding .tar.bz2 (BZip2 + Tar)');
        final decompressed = BZip2Decoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(decompressed);
      } else if (name.endsWith('.tar')) {
        debugPrint('[ArchiveExtractor] decoding .tar (plain Tar)');
        archive = TarDecoder().decodeBytes(bytes);
      } else if (name.endsWith('.zip')) {
        debugPrint('[ArchiveExtractor] decoding .zip');
        archive = ZipDecoder().decodeBytes(bytes);
      } else {
        // Unknown extension — try tar then zip
        debugPrint('[ArchiveExtractor] unknown extension, auto-detecting…');
        try {
          archive = TarDecoder().decodeBytes(bytes);
        } catch (_) {
          archive = ZipDecoder().decodeBytes(bytes);
        }
      }
    } catch (e, st) {
      debugPrint('[ArchiveExtractor] FATAL decode failed for $archivePath: $e\n$st');
      return false;
    }

    debugPrint('[ArchiveExtractor] decoded ${archive.files.length} entries');

    // ------------------------------------------------------------------
    // 2. Extract — per-entry try/catch with path logging
    // ------------------------------------------------------------------
    final destCanonical = p.canonicalize(destDir);
    int ok = 0, skipped = 0, failed = 0;

    for (final entry in archive.files) {
      // Rootfs tarballs may store absolute paths ("/bin/sh") or relative
      // ("bin/sh"). Always strip the leading "/" so paths stay under destDir
      // (package:path.join would otherwise treat "/bin/sh" as absolute and
      // escape / skip the entry via the zip-slip guard).
      var rawName = entry.name.replaceAll('\\', '/');
      while (rawName.startsWith('/')) {
        rawName = rawName.substring(1);
      }
      if (rawName.isEmpty || rawName == '.') continue;

      final entryPath = p.join(destDir, p.normalize(rawName));

      // Zip-slip guard
      if (!p.isWithin(destCanonical, p.canonicalize(entryPath))) {
        debugPrint('[ArchiveExtractor] SKIPPED (zip-slip): ${entry.name}');
        skipped++;
        continue;
      }

      try {
        // --- Symlink (check BEFORE isFile — symlinks may report isFile=true) ---
        if (entry.isSymbolicLink) {
          var target = entry.nameOfLinkedFile;
          if (target.isEmpty) {
            debugPrint('[ArchiveExtractor] SKIPPED (empty symlink target): ${entry.name}');
            skipped++;
            continue;
          }
          // Absolute symlink targets (e.g. "/bin/busybox") are normal inside a
          // rootfs — they are guest paths resolved by proot, NOT host paths.
          // Preserve them as-is. Relative targets must stay under destDir.
          if (!p.isAbsolute(target)) {
            final linkParent = p.dirname(entryPath);
            final resolvedTarget = p.normalize(p.join(linkParent, target));
            if (!p.isWithin(destCanonical, p.canonicalize(resolvedTarget))) {
              debugPrint(
                  '[ArchiveExtractor] SKIPPED (symlink escapes dest): '
                  '${entry.name} -> $target');
              skipped++;
              continue;
            }
          }

          // Ensure parent directory exists
          await Directory(p.dirname(entryPath)).create(recursive: true);

          // Remove any existing file/link/dir at this path to avoid
          // "File exists" / "Permission Denied"
          await _removeIfExists(entryPath);

          await Link(entryPath).create(target, recursive: false);
          ok++;
          continue;
        }

        // --- Directory ---
        if (!entry.isFile) {
          await Directory(entryPath).create(recursive: true);
          ok++;
          continue;
        }

        // --- Regular file ---
        await Directory(p.dirname(entryPath)).create(recursive: true);
        await _removeIfExists(entryPath);

        final out = File(entryPath);
        final bytesOut = entry.content as List<int>;
        await out.writeAsBytes(bytesOut, flush: false);

        // Restore POSIX permissions (best effort — chmod may not exist)
        if (entry.mode != 0) {
          try {
            final oct = (entry.mode & 0x1FF).toRadixString(8).padLeft(3, '0');
            final result = await Process.run('chmod', [oct, entryPath]);
            if (result.exitCode != 0) {
              // Non-fatal — Android often lacks chmod for app-private paths
            }
          } catch (_) {
            // chmod unavailable — ignore, PRoot will handle at runtime
          }
        }

        ok++;
      } on FileSystemException catch (e) {
        // Permission Denied / File exists / Too many open files etc.
        failed++;
        debugPrint(
            '[ArchiveExtractor] FileSystemException on "${entry.name}" '
            '($entryPath): ${e.message} (errno=${e.osError?.errorCode})');
      } catch (e, st) {
        failed++;
        debugPrint(
            '[ArchiveExtractor] FAILED on "${entry.name}" ($entryPath): $e\n$st');
      }
    }

    debugPrint(
        '[ArchiveExtractor] done: $ok ok, $skipped skipped, $failed failed '
        'out of ${archive.files.length}');

    // Consider it successful if most entries extracted (symlinks to /dev etc.
    // may legitimately fail inside filesDir on some devices)
    return ok > 0 && failed < archive.files.length;
  }

  /// Delete [path] if it exists as file, link, or directory — swallow errors.
  static Future<void> _removeIfExists(String path) async {
    try {
      final link = Link(path);
      if (await link.exists()) {
        await link.delete();
        return;
      }
    } catch (_) {}
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        return;
      }
    } catch (_) {}
    try {
      final d = Directory(path);
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {}
  }
}
