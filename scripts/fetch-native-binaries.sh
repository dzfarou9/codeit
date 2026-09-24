#!/usr/bin/env bash
# fetch-native-binaries.sh — Populate jniLibs/arm64-v8a (primary) and
# assets/bin (fallback copy source) for codeit.
# Requires: curl, file
# Run from repo root: bash scripts/fetch-native-binaries.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNILIBS="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
ASSETS="$ROOT/assets/bin"
mkdir -p "$JNILIBS" "$ASSETS"

fetch_one() {
  local url="$1" dest_jni="$2" dest_asset="$3" label="$4"
  if [ -z "$url" ]; then
    echo "[fetch] SKIP $label — set its *_URL env var"
    return 0
  fi
  echo "[fetch] $label from $url"
  curl -fL --retry 3 -o "$dest_jni" "$url"
  chmod +x "$dest_jni"
  cp -f "$dest_jni" "$dest_asset"
  chmod +x "$dest_asset"
  file "$dest_jni" || true
}

echo "[fetch] jniLibs → $JNILIBS"
echo "[fetch] assets  → $ASSETS"

# proot (static aarch64-linux-android)
fetch_one "${PROOT_URL:-}" \
  "$JNILIBS/libproot.so" "$ASSETS/libproot.so" "proot"

# busybox / bash fallback
fetch_one "${BUSYBOX_URL:-}" \
  "$JNILIBS/libbash.so" "$ASSETS/libbash.so" "busybox/bash"

# bsdtar (libarchive)
fetch_one "${BSDTAR_URL:-}" \
  "$JNILIBS/libtar.so" "$ASSETS/libtar.so" "bsdtar"

echo ""
echo "[fetch] jniLibs contents:"
ls -lh "$JNILIBS/"
echo "[fetch] assets/bin contents:"
ls -lh "$ASSETS/"
echo ""
echo "libpty.so is built automatically by CMake via externalNativeBuild."
echo "No manual step needed — cd android && ./gradlew :app:assembleDebug"
