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

On Linux the same `main.zig` prints the URL and tries `xdg-open`. WKWebView
is macOS-only — that is a merjs limitation, not a graff one. The existing
Tauri app in `gui/` is unchanged.
