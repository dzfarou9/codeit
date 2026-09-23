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

  // Termux / proot-distro mirror configuration
  // Primary: ghcr.io / github releases for proot-distro rootfs
  // Fallback: Termux package mirrors for bootstrap archives
  static const List<RootfsDistro> availableDistros = [
    RootfsDistro(
      id: 'ubuntu',
      displayName: 'Ubuntu 22.04 (Jammy)',
      // Official proot-distro Ubuntu rootfs — aarch64 minimal
      // Source: https://github.com/termux/proot-distro
      // These are resolved at install time; URLs are templated because
      // release tags move. RootfsInstaller tries each mirror in order.
      mirrors: [
        // GitHub releases via proot-distro (most reliable)
        'https://github.com/termux/proot-distro/releases/download/v4.18.0/ubuntu-aarch64-pd-v4.18.0.tar.xz',
        // Termux bootstrap fallback (if proot-distro unavailable, use bootstrap as base)
        'https://packages.termux.dev/bootstrap/aarch64/bootstrap-aarch64.zip',
      ],
      archiveType: ArchiveType.tarXz,
      defaultShell: '/bin/bash',
      estimatedSizeMb: 145,
    ),
    RootfsDistro(
      id: 'alpine',
      displayName: 'Alpine 3.19 (Minimal)',
      mirrors: [
        'https://github.com/termux/proot-distro/releases/download/v4.18.0/alpine-aarch64-pd-v4.18.0.tar.xz',
        'https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.1-aarch64.tar.gz',
      ],
      archiveType: ArchiveType.tarGz,
      defaultShell: '/bin/sh',
      estimatedSizeMb: 35,
    ),
    RootfsDistro(
      id: 'debian',
      displayName: 'Debian 12 (Bookworm)',
      mirrors: [
        'https://github.com/termux/proot-distro/releases/download/v4.18.0/debian-aarch64-pd-v4.18.0.tar.xz',
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
