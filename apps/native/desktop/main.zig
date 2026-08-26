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

fn openLinux(url: []const u8) void {
    std.log.info("merjs-style shell: open {s} in a browser (WKWebView is macOS-only)", .{url});
}

pub fn main(init: std.process.Init) !void {
    const url = init.environ_map.get("GRAFF_NATIVE_URL") orelse "http://127.0.0.1:3000";
    if (comptime builtin.os.tag == .macos) {
        try runMac(url);
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

fn runMac(url: []const u8) !void {
    var url_buf: [256]u8 = undefined;
    const url_z = try std.fmt.bufPrintZ(&url_buf, "{s}", .{url});

    const app = send(cls("NSApplication"), sel("sharedApplication"));
    sendIntv(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);

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
    const request = send1(cls("NSURLRequest"), sel("requestWithURL:"), ns_url);
    _ = send1(webview, sel("loadRequest:"), request);

    send1v(window, sel("makeKeyAndOrderFront:"), null);
    sendBoolv(app, sel("activateIgnoringOtherApps:"), YES);
    sendv(app, sel("run"));
}
