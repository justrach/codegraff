# Sourced from build.sh after the UI and graff binary exist.
stage_linux_app() {
  local dist="$ui/node_modules/electron/dist"
  local app="$out/codegraff"
  if [[ ! -x "$dist/electron" ]]; then
    echo "Electron for this OS is not installed." >&2
    exit 1
  fi
  rm -rf "$app"
  mkdir -p "$app"
  cp -a "$dist/." "$app/"
  rm -f "$app/resources/default_app.asar"
  mv "$app/electron" "$app/codegraff.bin"
  chmod 755 "$app/codegraff.bin"
  local resources="$app/resources"
  mkdir -p "$resources/app" "$resources/native" "$resources/ui/.next"
  if [[ "${GRAFF_DEV:-0}" == "1" ]]; then touch "$resources/codegraff-development"; fi
  cp "$here/"*.cjs "$resources/app/"
  bun build "$here/updater-runtime.cjs" --target=node --format=cjs --external electron --outfile "$resources/app/updater-runtime.cjs"
  printf '{"name":"codegraff","productName":"%s","version":"%s","main":"main.cjs"}\n' "$app_name" "$version" > "$resources/app/package.json"
  cp -a "$ui/.next/standalone/." "$resources/ui/"
  cp -a "$ui/.next/static" "$resources/ui/.next/static"
  if [[ -d "$ui/public" ]]; then cp -a "$ui/public" "$resources/ui/public"; fi
  bun "$here/prepare-bundle.cjs" "$resources/ui"
  rm -rf "$resources/ui/node_modules/@img"
  cp -L "$(command -v bun)" "$resources/bun"
  chmod 755 "$resources/bun"
  cp "$root/zig-out/bin/graff" "$resources/graff"
  chmod 755 "$resources/graff"
  cc -O2 -Wall -Wextra "$here/native/terminal.c" -o "$resources/native/graff-terminal" -lutil
  chmod 755 "$resources/native/graff-terminal"
  bun "$here/build-icon.cjs" "$app/codegraff.png" 256
  cp "$here/linux/codegraff.sh" "$app/codegraff"
  chmod 755 "$app/codegraff"
  cat > "$app/codegraff.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$app_name
Exec=$app/codegraff %U
Icon=$app/codegraff.png
Terminal=false
Categories=Development;
StartupWMClass=codegraff
EOF
  for file in "$app/codegraff" "$app/codegraff.bin" "$resources/graff" "$resources/bun" "$resources/native/graff-terminal" "$resources/ui/server.js" "$resources/app/main.cjs" "$app/codegraff.png"; do
    if [[ ! -e "$file" ]]; then
      echo "Linux bundle is missing $file" >&2
      exit 1
    fi
  done
  if [[ -e "$resources/native/activity.node" ]]; then
    echo "Linux bundle must not include the macOS activity addon." >&2
    exit 1
  fi
  package_linux_deb "$app"
  if ! package_linux_appimage "$app"; then
    echo "AppImage tool unavailable; unpacked app and deb are ready." >&2
  fi
  echo "$app"
}

package_linux_deb() {
  local app="$1" arch
  # Debian sorts a tilde prerelease before its matching stable version.
  # Keep the app and graff binary on the canonical -beta version.
  local deb_version="${version/-beta./~beta.}"
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "No deb for $(uname -m)" >&2; return 0 ;;
  esac
  local stage="$out/deb-root"
  rm -rf "$stage"
  mkdir -p "$stage/DEBIAN" "$stage/opt" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/256x256/apps"
  cp -a "$app" "$stage/opt/codegraff"
  cat > "$stage/usr/share/applications/codegraff.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$app_name
Exec=/opt/codegraff/codegraff %U
Icon=codegraff
Terminal=false
Categories=Development;
StartupWMClass=codegraff
EOF
  cp "$app/codegraff.png" "$stage/usr/share/icons/hicolor/256x256/apps/codegraff.png"
  ln -s /opt/codegraff/codegraff "$stage/usr/bin/codegraff"
  cat > "$stage/DEBIAN/control" <<EOF
Package: codegraff
Version: ${deb_version}
Section: devel
Priority: optional
Architecture: ${arch}
Maintainer: Codegraff <support@codegraff.com>
Depends: libgtk-3-0 | libgtk-3-0t64, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0 | libatspi2.0-0t64, libuuid1, libsecret-1-0, libasound2 | libasound2t64, libgbm1
Description: Codegraff desktop
 Graphical client for the graff harness.
EOF
  cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
helper=/opt/codegraff/chrome-sandbox
if [ -f "$helper" ]; then
  chown root:root "$helper" 2>/dev/null || true
  chmod 4755 "$helper" 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0
EOF
  chmod 755 "$stage/DEBIAN/postinst"
  dpkg-deb --root-owner-group --build "$stage" "$out/codegraff_${deb_version}_${arch}.deb"
}

package_linux_appimage() {
  local app="$1" tool=""
  if command -v appimagetool >/dev/null 2>&1; then tool="$(command -v appimagetool)"
  elif [[ -n "${APPIMAGETOOL:-}" && -x "${APPIMAGETOOL}" ]]; then tool="$APPIMAGETOOL"
  else return 1
  fi
  local dir="$out/Codegraff.AppDir"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -a "$app/." "$dir/"
  cp "$dir/codegraff" "$dir/AppRun"
  chmod 755 "$dir/AppRun"
  cat > "$dir/codegraff.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$app_name
Exec=codegraff
Icon=codegraff
Categories=Development;
EOF
  cp "$app/codegraff.png" "$dir/codegraff.png"
  (cd "$out" && ARCH="$(uname -m)" "$tool" "$dir" "$out/codegraff-${version}-$(uname -m).AppImage")
}
