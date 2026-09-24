library;
// Global constants for codeit (com.farou9.codeit)

class AppConstants {
  static const String appName = 'codeit';
  static const String packageName = 'com.farou9.codeit';

  // Channels — must match MainActivity.kt
  static const String methodChannel = 'com.farou9.codeit/engine';
  static const String eventChannel = 'com.farou9.codeit/ptyOutput';

  // SharedPreferences keys
  static const String keyIsInstalled = 'is_installed';
  static const String keyInstalledDistro = 'installed_distro';
  static const String keyRootfsVersion = 'rootfs_version';

  // Official direct CDN links for arm64-v8a rootfs archives.
  // Each distro lists mirrors in priority order; RootfsInstaller tries them
  // sequentially. All served over HTTPS with redirects enabled in Dio.
  static const List<RootfsDistro> availableDistros = [
    RootfsDistro(
      id: 'ubuntu',
      displayName: 'Ubuntu 22.04 (Jammy)',
      mirrors: [
        'https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz',
      ],
      archiveType: ArchiveType.tarGz,
      defaultShell: '/bin/bash',
      estimatedSizeMb: 145,
    ),
    RootfsDistro(
      id: 'alpine',
      displayName: 'Alpine 3.20 (Minimal)',
      mirrors: [
        'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz',
      ],
      archiveType: ArchiveType.tarGz,
      defaultShell: '/bin/sh',
      estimatedSizeMb: 35,
    ),
    RootfsDistro(
      id: 'debian',
      displayName: 'Debian 12 (Bookworm)',
      mirrors: [
        'https://deb.debian.org/debian-images/debian-12-generic-arm64.tar.xz',
      ],
      archiveType: ArchiveType.tarXz,
      defaultShell: '/bin/bash',
      estimatedSizeMb: 120,
    ),
  ];

  static RootfsDistro get defaultDistro => availableDistros.first;
}

enum ArchiveType { tarXz, tarGz, tarBz2, zip }

class RootfsDistro {
  final String id;
  final String displayName;
  final List<String> mirrors;
  final ArchiveType archiveType;
  final String defaultShell;
  final int estimatedSizeMb;

  const RootfsDistro({
    required this.id,
    required this.displayName,
    required this.mirrors,
    required this.archiveType,
    required this.defaultShell,
    required this.estimatedSizeMb,
  });
}
