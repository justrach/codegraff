#!/usr/bin/env bash
# Idempotent bootstrap for the Cursor Cloud Agent environment.
#
# Installs the exact checksum-pinned Zig nightly the repository targets (the
# same version and SHA-256 the CI installer verifies) onto PATH, then warms the
# `graff` build so the harness is ready to run. Safe to run repeatedly.
set -euo pipefail

# Keep these two in lockstep with scripts/install-zig-ci.py.
ZIG_VERSION="0.17.0-dev.813+2153f8143"
ZIG_LINUX_X86_64_SHA256="b0d46ffc4587b9e8dd0b524ee5bc4da1e67f28bba55e7c534cec64af2f2d7a74"

ZIG_ARCHIVE="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
ZIG_PREFIX="/opt/codegraff-zig"
ZIG_LINK="/usr/local/bin/zig"
MIRRORS=(
  "https://pkg.machengine.org/zig"
  "https://zigmirror.hryx.net/zig"
  "https://zig.linus.dev/zig"
)

log() { printf '==> %s\n' "$*"; }

# Elevate only when the target is not already writable by this user.
maybe_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_zig() {
  if command -v zig >/dev/null 2>&1 && [ "$(zig version 2>/dev/null)" = "$ZIG_VERSION" ]; then
    log "Zig $ZIG_VERSION already on PATH"
    return
  fi

  local tmp archive got
  tmp="$(mktemp -d)"
  archive="${tmp}/${ZIG_ARCHIVE}"

  local ok=0
  for mirror in "${MIRRORS[@]}"; do
    log "Downloading ${mirror}/${ZIG_ARCHIVE}"
    if curl -fsSL -A "codegraff-cloud-agent-zig-installer/1" "${mirror}/${ZIG_ARCHIVE}" -o "$archive"; then
      ok=1
      break
    fi
  done
  [ "$ok" -eq 1 ] || { echo "all Zig mirrors failed" >&2; exit 1; }

  got="$(sha256sum "$archive" | cut -d' ' -f1)"
  if [ "$got" != "$ZIG_LINUX_X86_64_SHA256" ]; then
    echo "Zig SHA-256 mismatch: expected ${ZIG_LINUX_X86_64_SHA256}, got ${got}" >&2
    exit 1
  fi
  log "Zig archive verified (SHA-256 ok)"

  maybe_sudo rm -rf "$ZIG_PREFIX"
  maybe_sudo mkdir -p "$ZIG_PREFIX"
  maybe_sudo tar -xJf "$archive" -C "$ZIG_PREFIX" --strip-components=1
  # Zig resolves its lib/ directory relative to the real binary (symlinks are
  # followed), so a bare symlink onto PATH is enough.
  maybe_sudo ln -sf "${ZIG_PREFIX}/zig" "$ZIG_LINK"
  rm -rf "$tmp"

  log "Installed Zig $(zig version)"
}

main() {
  cd "$(dirname "$0")/.."
  install_zig
  log "Building the graff harness (zig build)"
  zig build
  log "Environment ready: $(./zig-out/bin/graff --version | head -n 1)"
}

main "$@"
