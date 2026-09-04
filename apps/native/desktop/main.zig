//! merjs-style native shell for the Codegraff Beautiful UI harness.
//!
//! Copied from merjs `examples/desktop/main.zig` (ObjC / WKWebView, no
//! Electron): open a native window onto a local URL. Here the URL is the
//! Next.js UI (`apps/native`) instead of a merjs SSR server. On macOS this
//! is an NSWindow + WKWebView. Elsewhere it prints the URL (and tries
//! xdg-open) so the same binary is useful on Linux CI/dev hosts.
//!
//!   zig build-exe apps/native/desktop/main.zig -O ReleaseSmall -femit-bin=zig-out/bin/graff-native
//!   GRAFF_NATIVE_URL=http://127.0.0.1:3000 ./zig-out/bin/graff-native
const std = @import("std");
const builtin = @import("builtin");
const update = @import("update.zig");

/// The Dock and ⌘-Tab icon. A bare binary has no bundle to read an icon
/// from, so the image travels inside it and is handed to NSApplication at
/// startup. Same artwork as the desktop app's own icon.
const icon_png = @embedFile("icon.png");

fn openLinux(url: []const u8) void {
    std.log.info("merjs-style shell: open {s} in a browser (WKWebView is macOS-only)", .{url});
}

/// Where the UI is served. A bundled app is launched from Finder with no
/// environment to inherit, so when `GRAFF_NATIVE_URL` is unset the shell
/// looks for a dev server on the ports this app uses, newest first, and
/// falls back to the first of them so the window still opens (and shows
/// the browser's own "cannot connect" page) when nothing is listening.
const default_urls = [_][]const u8{ "http://127.0.0.1:3777", "http://127.0.0.1:3000" };

/// Shown when no interface is serving. The window is a shell around a local
/// app that is not inside the bundle, and a blank connection error tells a
/// first-time user nothing about that.
const no_server_html =
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<style>
    \\:root{color-scheme:light dark}
    \\body{margin:0;display:grid;place-items:center;min-height:100vh;
    \\font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
    \\background:Canvas;color:CanvasText}
    \\main{max-width:34rem;padding:2rem}
    \\h1{font-size:1.15rem;margin:0 0 .75rem}
    \\p{margin:0 0 1rem;opacity:.85}
    \\pre{background:color-mix(in oklab,CanvasText 8%, Canvas);padding:.75rem 1rem;
    \\border-radius:8px;overflow-x:auto;font-size:13px}
    \\code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    \\</style>
    \\<main>
    \\<h1>The interface is not running yet</h1>
    \\<p>This window shows the codegraff interface, which runs on your machine
    \\and is not part of the app. Start it from a checkout of the repository:</p>
    \\<pre><code>zig build                 # builds the graff binary
    \\cd apps/native
    \\npm install &amp;&amp; npm run dev   # serves the interface</code></pre>
    \\<p>Then reopen this app. It looks for the interface on port 3777, then
    \\3000. To point it somewhere else, launch it from a terminal with
    \\<code>GRAFF_NATIVE_URL</code> set.</p>
    \\</main>
;

fn listening(url: []const u8) bool {
    // "http://127.0.0.1:<port>" — the port is what follows the last colon.
    const colon = std.mem.lastIndexOfScalar(u8, url, ':') orelse return false;
    const port = std.fmt.parseInt(u16, url[colon + 1 ..], 10) catch return false;
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

pub fn main(init: std.process.Init) !void {
    var serving = true;
    const url = init.environ_map.get("GRAFF_NATIVE_URL") orelse blk: {
        for (default_urls) |candidate| {
            if (listening(candidate)) break :blk candidate;
        }
        // Nothing is listening. The app is a window onto an interface it does
        // not contain, so this is the normal first-run state, not a fault —
        // say what to start rather than showing WebKit's connection error.
        serving = false;
        break :blk default_urls[0];
    };
    // Set this to pin a build: a machine mid-debug should not have the app
    // swapped underneath it because a release happened to land.
    const updates = init.environ_map.get("GRAFF_NATIVE_NO_UPDATE") == null;
    if (comptime builtin.os.tag == .macos) {
        try runMac(url, updates, serving);
    } else {
        openLinux(url);
    }
}

// ── macOS AppKit / WKWebView (merjs examples/desktop) ─────────────────

extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void;

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const NSUInteger = c_ulong;
const NSInteger = c_long;
const BOOL = i8;

const NSWindowStyleMaskTitled: NSUInteger = 1;
const NSWindowStyleMaskClosable: NSUInteger = 2;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 4;
const NSWindowStyleMaskResizable: NSUInteger = 8;
const NSBackingStoreBuffered: NSUInteger = 2;
const NSApplicationActivationPolicyRegular: NSInteger = 0;
/// NSURLRequestReloadIgnoringLocalCacheData. The window points at a dev
/// server whose bundle changes under it; WebKit's cache happily serves a
/// page from a previous build, which then fails to start against the new
/// one. Always fetch the document fresh.
const NSURLRequestReloadIgnoringLocalCacheData: NSUInteger = 1;
const load_timeout_s: f64 = 30;
const YES: BOOL = 1;
const NO: BOOL = 0;

fn cls(name: [*:0]const u8) Id {
    return objc_getClass(name);
}
fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}
fn send(recv: Id, s: Sel) Id {
    const F = *const fn (Id, Sel) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn sendv(recv: Id, s: Sel) void {
    const F = *const fn (Id, Sel) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn send1(recv: Id, s: Sel, a: Id) Id {
    const F = *const fn (Id, Sel, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn send1v(recv: Id, s: Sel, a: Id) void {
    const F = *const fn (Id, Sel, Id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendStr(recv: Id, s: Sel, str: [*:0]const u8) Id {
    const F = *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, str);
}
fn sendIntv(recv: Id, s: Sel, a: NSInteger) void {
    const F = *const fn (Id, Sel, NSInteger) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendBoolv(recv: Id, s: Sel, a: BOOL) void {
    const F = *const fn (Id, Sel, BOOL) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendWindowInit(recv: Id, s: Sel, rect: CGRect, style: NSUInteger, backing: NSUInteger, defer_: BOOL) Id {
    const F = *const fn (Id, Sel, CGRect, NSUInteger, NSUInteger, BOOL) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, rect, style, backing, defer_);
}
fn sendWebViewInit(recv: Id, s: Sel, frame: CGRect, config: Id) Id {
    const F = *const fn (Id, Sel, CGRect, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, frame, config);
}
fn send2(recv: Id, s: Sel, a: Id, b: Id) Id {
    const F = *const fn (Id, Sel, Id, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a, b);
}
fn sendRequestInit(recv: Id, s: Sel, url: Id, policy: NSUInteger, timeout: f64) Id {
    const F = *const fn (Id, Sel, Id, NSUInteger, f64) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, url, policy, timeout);
}
fn sendBytes(recv: Id, s: Sel, ptr: [*]const u8, len: NSUInteger) Id {
    const F = *const fn (Id, Sel, [*]const u8, NSUInteger) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, ptr, len);
}

/// Give the app its icon. Best effort: a shell without one still runs.
fn setAppIcon(app: Id) void {
    const data = sendBytes(cls("NSData"), sel("dataWithBytes:length:"), icon_png.ptr, icon_png.len);
    if (data == null) return;
    const image = send1(send(cls("NSImage"), sel("alloc")), sel("initWithData:"), data);
    if (image == null) return;
    send1v(app, sel("setApplicationIconImage:"), image);
}

/// This app's own bundle directory, as NSBundle reports it. For a loose
/// binary that is just the directory it sits in, which has no Info.plist —
/// the updater treats that as "no version" and leaves it alone.
fn bundlePath(gpa: std.mem.Allocator) ?[]const u8 {
    const bundle = send(cls("NSBundle"), sel("mainBundle"));
    if (bundle == null) return null;
    const ns_path = send(bundle, sel("bundlePath"));
    if (ns_path == null) return null;
    const c_str = send(ns_path, sel("UTF8String"));
    if (c_str == null) return null;
    const text: [*:0]const u8 = @ptrCast(c_str.?);
    return gpa.dupe(u8, std.mem.span(text)) catch null;
}

/// The check runs off the main thread and owns nothing the window needs, so
/// a slow or dead network delays an update and never the UI.
fn updateWorker(bundle: []const u8) void {
    update.check(std.heap.page_allocator, bundle);
}

fn runMac(url: []const u8, updates: bool, serving: bool) !void {
    var url_buf: [256]u8 = undefined;
    const url_z = try std.fmt.bufPrintSentinel(&url_buf, "{s}", .{url}, 0);

    const app = send(cls("NSApplication"), sel("sharedApplication"));
    sendIntv(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    setAppIcon(app);

    const frame = CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1280, .height = 820 } };
    const style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    const window = sendWindowInit(
        send(cls("NSWindow"), sel("alloc")),
        sel("initWithContentRect:styleMask:backing:defer:"),
        frame,
        style,
        NSBackingStoreBuffered,
        NO,
    );
    const title = sendStr(cls("NSString"), sel("stringWithUTF8String:"), "Codegraff");
    send1v(window, sel("setTitle:"), title);

    const wkconfig = send(send(cls("WKWebViewConfiguration"), sel("alloc")), sel("init"));
    const webview = sendWebViewInit(
        send(cls("WKWebView"), sel("alloc")),
        sel("initWithFrame:configuration:"),
        frame,
        wkconfig,
    );
    send1v(window, sel("setContentView:"), webview);

    const ns_url_str = sendStr(cls("NSString"), sel("stringWithUTF8String:"), url_z.ptr);
    const ns_url = send1(cls("NSURL"), sel("URLWithString:"), ns_url_str);
    const request = sendRequestInit(
        cls("NSURLRequest"),
        sel("requestWithURL:cachePolicy:timeoutInterval:"),
        ns_url,
        NSURLRequestReloadIgnoringLocalCacheData,
        load_timeout_s,
    );
    if (serving) {
        _ = send1(webview, sel("loadRequest:"), request);
    } else {
        const html = sendStr(cls("NSString"), sel("stringWithUTF8String:"), no_server_html.ptr);
        _ = send2(webview, sel("loadHTMLString:baseURL:"), html, null);
    }

    send1v(window, sel("makeKeyAndOrderFront:"), null);
    sendBoolv(app, sel("activateIgnoringOtherApps:"), YES);

    // Started after the window is up so the first thing the user sees is
    // their UI, never a dialog about the app itself.
    if (updates) {
        if (bundlePath(std.heap.page_allocator)) |bundle| {
            if (std.Thread.spawn(.{}, updateWorker, .{bundle})) |thread| {
                thread.detach();
            } else |_| {}
        }
    }

    sendv(app, sel("run"));
}
