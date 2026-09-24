#!/usr/bin/env bash
# fetch-native-binaries.sh — Populate jniLibs/arm64-v8a (primary) and
# assets/bin (fallback) for codeit with static aarch64 binaries.
#
# Sources (no env vars required — defaults work out of the box):
#   proot    ← Alpine proot-static  (truly static, no libtalloc/libshmem deps)
#   busybox  ← Alpine busybox-static (provides /bin/sh, tar, etc. inside rootfs
#                                       AND as host-side libbash.so fallback)
#   tar      ← optional; Dart ArchiveExtractor is the fallback if omitted
#
# Usage (from repo root):
#   bash scripts/fetch-native-binaries.sh
#
# Override sources if needed:
#   PROOT_URL=... BUSYBOX_URL=... BSDTAR_URL=... bash scripts/fetch-native-binaries.sh
#
# Requires: curl, tar (bsdtar or GNU tar), readelf (optional, for verify)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNILIBS="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
ASSETS="$ROOT/assets/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$JNILIBS" "$ASSETS"

# ---------------------------------------------------------------------------
# Default sources — Alpine Linux edge, aarch64, STATIC builds
# ---------------------------------------------------------------------------
# proot-static 5.4.0-r2 — ~402 KB, ELF AArch64, no INTERP, no NEEDED
PROOT_URL_DEFAULT="https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/proot-static-5.4.0-r2.apk"
# busybox-static 1.38.0-r7 — ~1.1 MB, ELF AArch64, no INTERP, no NEEDED
BUSYBOX_URL_DEFAULT="https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64/busybox-static-1.38.0-r7.apk"
# Optional GNU tar is dynamically linked on Alpine — leave empty to rely on
# Dart ArchiveExtractor (recommended). Set BSDTAR_URL to override.
BSDTAR_URL_DEFAULT=""

PROOT_URL="${PROOT_URL:-$PROOT_URL_DEFAULT}"
BUSYBOX_URL="${BUSYBOX_URL:-$BUSYBOX_URL_DEFAULT}"
BSDTAR_URL="${BSDTAR_URL:-$BSDTAR_URL_DEFAULT}"

log()  { printf '[fetch] %s\n' "$*"; }
fail() { printf '[fetch] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# download URL → file
download() {
  local url="$1" out="$2"
  log "Downloading $url"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$url" \
    || fail "download failed: $url"
}

# extract_apk APK_FILE DEST_DIR — Alpine .apk is a gzipped tar (signature first)
extract_apk() {
  local apk="$1" dest="$2"
  mkdir -p "$dest"
  # .apk = concatenated gzip members; tar extracts the data member fine
  tar -xzf "$apk" -C "$dest" 2>/dev/null || \
    tar -xzf "$apk" -C "$dest" --exclude='.SIGN.*' --exclude='.PKGINFO' 2>/dev/null || \
    fail "could not extract $apk"
}

# extract_deb DEB_FILE DEST_DIR — ar archive containing data.tar.*
extract_deb() {
  local deb="$1" dest="$2"
  mkdir -p "$dest"
  local tmp="$dest/.deb-tmp"
  mkdir -p "$tmp"
  (cd "$tmp" && ar x "$deb") || fail "ar failed on $deb"
  local data
  data=$(ls "$tmp"/data.tar.* 2>/dev/null | head -1) || fail "no data.tar in $deb"
  tar -xf "$data" -C "$dest" || fail "extract $data failed"
  rm -rf "$tmp"
}

# install_binary SRC DEST_LABEL — copy to jniLibs + assets, chmod +x, verify
install_binary() {
  local src="$1" label="$2"
  local base
  base=$(basename "$src")
  log "Installing $label ← $base"

  # Architecture check (ELF AArch64) when readelf available
  if command -v readelf >/dev/null 2>&1; then
    local machine
    machine=$(readelf -h "$src" 2>/dev/null | awk -F: '/Machine:/{print $2}' | xargs || true)
    if [[ -n "$machine" && "$machine" != *AArch64* && "$machine" != *ARM\ aarch64* ]]; then
      fail "$label is not AArch64 (got: $machine) — wrong architecture"
    fi
    local interp needed
    interp=$(readelf -l "$src" 2>/dev/null | grep INTERP || true)
    needed=$(readelf -d "$src" 2>/dev/null | grep NEEDED || true)
    if [[ -n "$interp" || -n "$needed" ]]; then
      log "WARN: $label is dynamically linked — may fail outside its original distro"
      [[ -n "$interp" ]] && log "  INTERP: $interp"
      [[ -n "$needed" ]] && log "  NEEDED: $needed"
    else
      log "  OK: static AArch64 (no INTERP, no NEEDED)"
    fi
  fi

  cp -f "$src" "$JNILIBS/$label"
  chmod 755 "$JNILIBS/$label"
  cp -f "$src" "$ASSETS/$label"
  chmod 755 "$ASSETS/$label"
}

# ---------------------------------------------------------------------------
# 1. proot → libproot.so
# ---------------------------------------------------------------------------
log "=== proot ==="
if [[ -n "$PROOT_URL" ]]; then
  if [[ "$PROOT_URL" == *.apk ]]; then
    download "$PROOT_URL" "$WORK/proot.apk"
    extract_apk "$WORK/proot.apk" "$WORK/proot-x"
    # binary is usually usr/bin/proot.static or bin/proot
    PROOT_BIN=$(find "$WORK/proot-x" -type f \( -name 'proot' -o -name 'proot.static' \) | head -1)
  elif [[ "$PROOT_URL" == *.deb ]]; then
    download "$PROOT_URL" "$WORK/proot.deb"
    extract_deb "$WORK/proot.deb" "$WORK/proot-x"
    PROOT_BIN=$(find "$WORK/proot-x" -type f -name 'proot' | head -1)
  else
    download "$PROOT_URL" "$WORK/proot.bin"
    PROOT_BIN="$WORK/proot.bin"
  fi
  [[ -n "${PROOT_BIN:-}" && -f "$PROOT_BIN" ]] || fail "proot binary not found after extract"
  install_binary "$PROOT_BIN" "libproot.so"
else
  log "SKIP proot (PROOT_URL empty)"
fi

# ---------------------------------------------------------------------------
# 2. busybox → libbash.so
# ---------------------------------------------------------------------------
log "=== busybox ==="
if [[ -n "$BUSYBOX_URL" ]]; then
  if [[ "$BUSYBOX_URL" == *.apk ]]; then
    download "$BUSYBOX_URL" "$WORK/busybox.apk"
    extract_apk "$WORK/busybox.apk" "$WORK/bb-x"
    BB_BIN=$(find "$WORK/bb-x" -type f \( -name 'busybox' -o -name 'busybox.static' \) | head -1)
  elif [[ "$BUSYBOX_URL" == *.deb ]]; then
    download "$BUSYBOX_URL" "$WORK/busybox.deb"
    extract_deb "$BUSYBOX_URL" "$WORK/bb-x" 2>/dev/null || extract_deb "$WORK/busybox.deb" "$WORK/bb-x"
    BB_BIN=$(find "$WORK/bb-x" -type f -name 'busybox' | head -1)
  else
    download "$BUSYBOX_URL" "$WORK/busybox.bin"
    BB_BIN="$WORK/busybox.bin"
  fi
  [[ -n "${BB_BIN:-}" && -f "$BB_BIN" ]] || fail "busybox binary not found after extract"
  install_binary "$BB_BIN" "libbash.so"
else
  log "SKIP busybox (BUSYBOX_URL empty)"
fi

# ---------------------------------------------------------------------------
# 3. tar/bsdtar → libtar.so (OPTIONAL — Dart ArchiveExtractor is the fallback)
# ---------------------------------------------------------------------------
log "=== tar (optional) ==="
if [[ -n "$BSDTAR_URL" ]]; then
  if [[ "$BSDTAR_URL" == *.apk ]]; then
    download "$BSDTAR_URL" "$WORK/tar.apk"
    extract_apk "$WORK/tar.apk" "$WORK/tar-x"
    TAR_BIN=$(find "$WORK/tar-x" -type f \( -name 'bsdtar' -o -name 'tar' -o -name 'tar.static' \) | head -1)
  elif [[ "$BSDTAR_URL" == *.deb ]]; then
    download "$BSDTAR_URL" "$WORK/tar.deb"
    extract_deb "$WORK/tar.deb" "$WORK/tar-x"
    TAR_BIN=$(find "$WORK/tar-x" -type f \( -name 'bsdtar' -o -name 'tar' \) | head -1)
  else
    download "$BSDTAR_URL" "$WORK/tar.bin"
    TAR_BIN="$WORK/tar.bin"
  fi
  [[ -n "${TAR_BIN:-}" && -f "$TAR_BIN" ]] || fail "tar binary not found after extract"
  install_binary "$TAR_BIN" "libtar.so"
else
  log "SKIP tar — Dart ArchiveExtractor will handle rootfs extraction"
fi

# ---------------------------------------------------------------------------
# Summary + verification
# ---------------------------------------------------------------------------
echo ""
log "=== jniLibs/arm64-v8a ==="
ls -lh "$JNILIBS/" || true
echo ""
log "=== assets/bin ==="
ls -lh "$ASSETS/" || true
echo ""

missing=0
for f in libproot.so libbash.so; do
  if [[ ! -f "$JNILIBS/$f" ]]; then
    log "MISSING: $JNILIBS/$f"
    missing=1
  fi
done
[[ $missing -eq 0 ]] || fail "required binaries missing — build would fail at runtime"

log "All required binaries present."
log "libpty.so is built automatically by CMake (externalNativeBuild)."
log ""
log "Verify APK packaging after build:"
log "  unzip -lv build/app/outputs/flutter-apk/app-release.apk | grep 'lib/arm64-v8a/'"
log "  # must list: libproot.so  libbash.so  libpty.so  libflutter.so  libapp.so"
