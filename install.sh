#!/usr/bin/env bash
set -euo pipefail

# graff-harness installer. Prefers a prebuilt binary from the latest GitHub
# release; falls back to building from source with Zig. Styled after the
# codedb/codegraff installers.
#
#   curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash
#   # or, from a checkout:  ./install.sh
#
# Env overrides: HARNESS_REPO (source repo), HARNESS_DIR (install dir),
# HARNESS_BUILD=source (skip the release download and compile).

REPO="${HARNESS_REPO:-https://github.com/justrach/codegraff}"
INSTALL_DIR="${HARNESS_DIR:-$HOME/bin}"
BIN="graff"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' N='\033[0m'

detect_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    MINGW*|MSYS*|CYGWIN*)
      printf "\n  ${W}harness installer${N}\n\n"
      printf "  ${Y}Windows detected${N} — run this inside ${G}WSL2${N} instead.\n\n"
      exit 0 ;;
    *) printf "  ${R}unsupported OS: $os${N}\n" >&2; exit 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) printf "  ${R}unsupported arch: $arch${N}\n" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

need_zig() {
  if ! command -v zig >/dev/null 2>&1; then
    printf "\n  ${R}error: zig not found${N} — harness needs the Zig 0.16 toolchain.\n"
    printf "  install it: ${C}brew install zig${N}  or  ${C}https://ziglang.org/download${N}\n\n" >&2
    exit 1
  fi
  local v; v="$(zig version 2>/dev/null || echo '?')"
  case "$v" in
    0.16.*) ;; # ok
    *) printf "  ${Y}warning:${N} zig $v detected; harness targets 0.16 — build may fail.\n" ;;
  esac
  printf "  ${D}zig${N}       $v\n"
}

# Drop the binary onto a *fresh inode*: overwriting a running macOS binary in
# place gets the replacement SIGKILLed by the kernel's signature cache.
place_bin() {
  mkdir -p "$INSTALL_DIR"
  rm -f "$INSTALL_DIR/$BIN"
  install -m 0755 "$1" "$INSTALL_DIR/$BIN"

  # Overwrite any *other* graff already on PATH (e.g. an older copy in
  # ~/.local/bin from the codegraff stack) so the binary we just installed
  # actually wins instead of being shadowed by a stale one earlier on PATH.
  # Fresh inode each time (rm then install) — same reason as above. Only
  # touch writable copies; never error on a protected/system path.
  oldifs="$IFS"; IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    [ "$d" = "$INSTALL_DIR" ] && continue
    if [ -f "$d/$BIN" ] && [ -w "$d/$BIN" ]; then
      if rm -f "$d/$BIN" && install -m 0755 "$1" "$d/$BIN" 2>/dev/null; then
        printf "  ${D}│${N} %-10s ${G}✓${N} (overwrote stale $d/$BIN)\n" "replace"
      fi
    fi
  done
  IFS="$oldifs"
}

# Try the latest GitHub release for this platform. Plain curl is the fast path
# now that the repo is public; gh is only a fallback for private forks.
fetch_release() {
  local platform="$1" target asset tmpd
  case "$platform" in
    darwin-arm64)  target="aarch64-macos" ;;
    darwin-x86_64) target="x86_64-macos" ;;
    linux-arm64)   target="aarch64-linux" ;;
    linux-x86_64)  target="x86_64-linux" ;;
    *) return 1 ;;
  esac
  # graff-named assets first; harness-named for releases that predate the
  # rename (the tarball's inner dir/binary follow the asset name).
  local stem
  for stem in graff harness; do
    asset="$stem-$target.tar.gz"
    tmpd="$(mktemp -d)"
    # Public repo: plain curl is the fast path (no auth, and it can't hang the
    # way `gh release download` has been observed to on some machines). Fall
    # back to gh only if curl fails — e.g. a private fork — and gh is present.
    if curl -fsSL --max-time 60 "$REPO/releases/latest/download/$asset" -o "$tmpd/$asset" 2>/dev/null; then
      :
    elif command -v gh >/dev/null 2>&1 \
      && gh release download --repo "${REPO#https://github.com/}" --pattern "$asset" --dir "$tmpd" >/dev/null 2>&1; then
      :
    else
      rm -rf "$tmpd"; continue
    fi
    break
  done
  [ -f "$tmpd/$asset" ] || { rm -rf "$tmpd"; return 1; }
  tar -xzf "$tmpd/$asset" -C "$tmpd" 2>/dev/null || { rm -rf "$tmpd"; return 1; }
  # Locate the extracted binary. CI (release.yml) nests it under
  # graff-<target>/, but hand-repacked macOS tarballs (the local notarize
  # flow) ship it flat at the root. Handle both, then fall back to a search
  # so a future layout change can't silently break the install again.
  local binpath=""
  if [ -f "$tmpd/$stem" ]; then
    binpath="$tmpd/$stem"
  elif [ -f "$tmpd/$stem-$target/$stem" ]; then
    binpath="$tmpd/$stem-$target/$stem"
  else
    binpath="$(find "$tmpd" -type f -name "$stem" 2>/dev/null | head -1)"
  fi
  [ -n "$binpath" ] && [ -f "$binpath" ] || { rm -rf "$tmpd"; return 1; }
  place_bin "$binpath"
  if [ "$(uname -s)" = "Darwin" ]; then
    # The release binary is already Developer-ID-signed + notarized — that both
    # satisfies Gatekeeper and avoids the Apple-Silicon SIGKILL, so leave it be.
    # Only ad-hoc re-sign when it does NOT already verify (older unsigned tarballs
    # or a source build); re-signing a notarized binary would strip its Developer ID.
    codesign --verify --strict "$INSTALL_DIR/$BIN" >/dev/null 2>&1 \
      || codesign -s - --force "$INSTALL_DIR/$BIN" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpd"
  # Fail closed: if the binary didn't actually land, return non-zero so the
  # caller falls back to a source build instead of falsely reporting success.
  # (set -e is suppressed inside the `if fetch_release` guard, so the install
  # error above does not abort on its own.)
  [ -x "$INSTALL_DIR/$BIN" ] || return 1
}

build_from_source() {
  local src tmp=""
  need_zig
  # Source: build in place if we're in the repo, else clone it.
  if [ -f build.zig ] && grep -qE '"(graff|harness)"' build.zig 2>/dev/null; then
    src="$(pwd)"
    printf "  ${D}│${N} %-10s ${G}✓${N} (current checkout)\n" "source"
  else
    command -v git >/dev/null 2>&1 || { printf "  ${R}error: git not found${N}\n" >&2; exit 1; }
    tmp="$(mktemp -d)"; src="$tmp/codegraff"
    printf "  ${D}│${N} %-10s " "clone"
    git clone --depth 1 "$REPO" "$src" >/dev/null 2>&1 \
      && printf "${G}✓${N}\n" \
      || { printf "${R}failed${N}\n\n  ${R}could not clone $REPO${N} (private repo — check your GitHub access)\n\n" >&2; exit 1; }
  fi

  printf "  ${D}│${N} %-10s " "build"
  ( cd "$src" && zig build -Doptimize=ReleaseFast ) >/dev/null 2>&1 \
    && printf "${G}✓${N}\n" \
    || { printf "${R}failed${N}\n\n  ${R}zig build failed${N} — run it manually in $src to see the error\n\n" >&2; exit 1; }

  # post-rename checkouts build zig-out/bin/graff; older ones harness
  if [ -f "$src/zig-out/bin/graff" ]; then
    place_bin "$src/zig-out/bin/graff"
  else
    place_bin "$src/zig-out/bin/harness"
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"
}

main() {
  local platform
  platform="$(detect_platform)"

  printf "\n  ${W}graff-harness${N} ${D}installer${N}\n\n"
  printf "  ${D}platform${N}  $platform\n"
  printf "  ${D}install${N}   $INSTALL_DIR\n\n"

  # Kick off the companion suite install in the background so it downloads in
  # parallel with the graff binary below — it's the slow part (a full curl|sh of
  # codedb-pro + the zigrep/zigread/zigpatch suite). Reaped before the summary.
  # Empty suite_pid = already present or opted out (HARNESS_NO_GRAFF) → nothing to wait on.
  # Tools installer = codegraff.com/install.sh; --max-time bounds it; override via GRAFF_SUITE_URL.
  GRAFF_SUITE_URL="${GRAFF_SUITE_URL:-https://codegraff.com/install.sh}"
  suite_pid=""; suite_log=""
  if [ -z "${HARNESS_NO_GRAFF:-}" ] && ! { command -v codedb-pro >/dev/null 2>&1 && command -v zigpatch >/dev/null 2>&1; }; then
    suite_log="$(mktemp)"
    ( curl -fsSL --max-time 120 "$GRAFF_SUITE_URL" | sh >/dev/null 2>&1 && echo ok || echo fail ) >"$suite_log" 2>&1 &
    suite_pid=$!
  fi

  if [ "${HARNESS_BUILD:-release}" != "source" ] && fetch_release "$platform"; then
    printf "  ${D}│${N} %-10s ${G}✓${N} (prebuilt release)\n" "download"
  else
    build_from_source
  fi

  printf "  ${D}│${N} %-10s ${G}✓${N}\n\n" "install"
  printf "  ${G}installed${N} ${D}→ $INSTALL_DIR/$BIN${N}\n"
  # Compat: the command used to be `harness` — the SDKs' fallback and old
  # shell habits keep working through a symlink.
  ln -sf "$INSTALL_DIR/$BIN" "$INSTALL_DIR/harness"

  # Reap the companion suite install that was kicked off in parallel at the top
  # of main() (muonry, zigrep/zigread/zigpatch, codedb — they back the @ picker,
  # the codedb tool, and zigpatch's atomic edit_file splices; the harness works
  # fully without it, premium paths just stay dormant). Skip with HARNESS_NO_GRAFF=1.
  if [ -z "${HARNESS_NO_GRAFF:-}" ]; then
    printf "  ${D}│${N} %-10s " "suite"
    if [ -z "$suite_pid" ]; then
      printf "${G}✓${N} (already present)\n"
    else
      wait "$suite_pid" 2>/dev/null || true
      if [ "$(cat "$suite_log" 2>/dev/null)" = ok ]; then
        printf "${G}✓${N} (muonry + zigrep suite)\n"
      else
        printf "${Y}skipped${N} ${D}(companion install unavailable — harness still fully functional)${N}\n"
      fi
      rm -f "$suite_log"
    fi
  fi

  # Optional skill (codex-style): kuri — browser automation, web crawling,
  # iOS/Android device control. Opt in here with HARNESS_WITH_KURI=1, or any
  # time later from inside the harness with `/skills add kuri`.
  if [ -n "${HARNESS_WITH_KURI:-}" ]; then
    if command -v kuri >/dev/null 2>&1; then
      printf "  ${D}│${N} %-10s ${G}✓${N} (already present)\n" "kuri"
    else
      printf "  ${D}│${N} %-10s " "kuri"
      if curl -fsSL https://raw.githubusercontent.com/justrach/kuri/main/install.sh | sh >/dev/null 2>&1; then
        printf "${G}✓${N} (browser automation)\n"
      else
        printf "${Y}skipped${N} ${D}(kuri install failed — try /skills add kuri later)${N}\n"
      fi
    fi
  else
    printf "  ${D}optional: kuri browser automation — HARNESS_WITH_KURI=1, or /skills add kuri in the harness${N}\n"
  fi

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
      printf "\n  ${Y}add to PATH:${N}\n"
      printf "  ${C}export PATH=\"$INSTALL_DIR:\$PATH\"${N}  ${D}(add to ~/.zshrc or ~/.bashrc)${N}\n"
      ;;
  esac

  printf "\n  ${W}done!${N} run ${C}$BIN${N} to start, or ${C}$BIN --help${N}\n\n"
}

main
