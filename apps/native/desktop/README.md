# merjs desktop shell

Native window for the Beautiful UI harness. The interop is the merjs
`examples/desktop` pattern (Zig → ObjC runtime → `NSWindow` + `WKWebView`,
no Electron, no merjs SSR). merjs itself stays a separate repo; we only
copied the window shell.

```bash
# UI (any OS) — Next.js spawns `graff acp` itself
# from the repo root: zig build
cd apps/native && npm install && npm run dev

# macOS window (after the UI is listening)
zig build-exe apps/native/desktop/main.zig -O ReleaseSmall \
  -femit-bin=zig-out/bin/graff-native \
  -framework AppKit -framework WebKit
GRAFF_NATIVE_URL=http://127.0.0.1:3000 ./zig-out/bin/graff-native
```

`icon.png` (the desktop app's own artwork, copied from `gui/src-tauri`)
is embedded in the binary and handed to `NSApplication` at startup, so the
Dock and ⌘-Tab show it even when the shell runs as a loose binary with no
bundle for macOS to read an icon from.

## A signed, notarized app

```bash
apps/native/desktop/build-app.sh                          # build + sign
NOTARIZE=1 apps/native/desktop/build-app.sh               # …and send it to Apple
NOTARIZE=1 INSTALL=1 apps/native/desktop/build-app.sh     # …and put it in /Applications
```

Install what was notarized, not a later re-signed build: re-signing
replaces the signature the stapled ticket belongs to, and the copy stops
being notarized. `INSTALL_DIR` moves the destination.

macOS only, and it refuses to run anywhere else: the shell is AppKit and
WKWebView, and every tool it uses (`iconutil`, `codesign`, `notarytool`)
comes with Xcode's command line tools. It writes `zig-out/macos/Codegraff.app`
— the binary named for the app, so the menu bar and ⌘-Tab say Codegraff,
the artwork converted to an `.icns`, and `Info.plist` beside them — signs
it with a Developer ID under the hardened runtime and a secure timestamp
(what notarization requires), then submits it, staples the ticket, and
checks it with `spctl -a -t install`, which is the check that matches how
the app is distributed. `-t exec` rejects notarized apps that did not come
from the App Store, so it is the wrong question to ask here.

Override `CODESIGN_IDENTITY` and `NOTARY_PROFILE` to sign as someone else.
The profile is made once with `xcrun notarytool store-credentials`.

Launched from Finder an app inherits no environment, so with
`GRAFF_NATIVE_URL` unset the shell looks for a dev server on 3777 and then
3000, and falls back to the first so the window still opens.

The document is fetched with `NSURLRequestReloadIgnoringLocalCacheData`.
The window points at a dev server whose bundle changes underneath it, and
WebKit will otherwise serve a page from an earlier build: the HTML loads,
its scripts never start against the new server, and the app sits on
"Connecting…" for good.

On Linux the same `main.zig` prints the URL and tries `xdg-open`. WKWebView
is macOS-only — that is a merjs limitation, not a graff one. The existing
Tauri app in `gui/` is unchanged.
