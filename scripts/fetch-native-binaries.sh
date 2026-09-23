#!/usr/bin/env bash
# fetch-native-binaries.sh — Populate jniLibs/arm64-v8a for codeit
# Requires: curl, unzip, file
# Run from repo root: bash scripts/fetch-native-binaries.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$DEST"

echo "[fetch] Destination: $DEST"

# --- proot (from termux/proot releases, if available as static aarch64) ---
# NOTE: Termux proot releases are typically not prebuilt as standalone static
# binaries. You may need to cross-compile:
#   git clone https://github.com/termux/proot
#   make -C src loader.built seccomp.built  # with aarch64-linux-android toolchain
# For now we attempt to fetch a known static build if the URL is configured.

if [ -n "${PROOT_URL:-}" ]; then
  echo "[fetch] proot from \$PROOT_URL"
  curl -L -o "$DEST/libproot.so" "$PROOT_URL"
  chmod +x "$DEST/libproot.so"
  file "$DEST/libproot.so" || true
else
  echo "[fetch] SKIP proot — set PROOT_URL to fetch, or cross-compile manually."
  echo "       See android/app/src/main/jniLibs/arm64-v8a/README.md"
fi

# --- busybox as bash fallback (static aarch64) ---
if [ -n "${BUSYBOX_URL:-}" ]; then
  echo "[fetch] busybox from \$BUSYBOX_URL"
  curl -L -o "$DEST/libbash.so" "$BUSYBOX_URL"
  chmod +x "$DEST/libbash.so"
else
  echo "[fetch] SKIP busybox/bash — set BUSYBOX_URL"
fi

# --- bsdtar (libarchive) ---
if [ -n "${BSDTAR_URL:-}" ]; then
  echo "[fetch] bsdtar from \$BSDTAR_URL"
  curl -L -o "$DEST/libtar.so" "$BSDTAR_URL"
  chmod +x "$DEST/libtar.so"
else
  echo "[fetch] SKIP bsdtar — set BSDTAR_URL"
fi

echo "[fetch] Done. Contents:"
ls -lh "$DEST/"
echo ""
echo "Build libpty.so via:  cd android && ./gradlew :app:assembleDebug"
