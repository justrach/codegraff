// native/main.zig — codegraff-gui native shell entry point.
//
// Boots the merjs HTTP server (serving the React SPA from dist/ + api/ routes
// + SSE /events) inside a system WKWebView. The React frontend talks to this
// Zig backend over HTTP.
//
//   zig build native        # run
//   zig build native-build  # prod binary
//   zig build package       # .app bundle
const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");
const native = mer.native;
const backend = @import("backend");

const log = std.log.scoped(.native);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var app_manifest = native.Manifest.fromZon(@import("manifest"));

    // CLI overrides.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dev")) {
            app_manifest.dev = true;
            app_manifest.server_mode = "dev";
        } else if (std.mem.eql(u8, args[i], "--no-dev")) {
            app_manifest.dev = false;
            app_manifest.server_mode = "embedded";
        }
    }

    if (!app_manifest.dev) {
        if (bundleResourcePath(allocator, args[0], "dist")) |bundle_dist| {
            app_manifest.static_dir = bundle_dist;
        } else |_| {}
    }

    // Initialize the backend runtime (Phase 1 stub; Phase 2 = real RuntimeManager).
    var rt = try backend.Runtime.init(allocator);
    defer rt.deinit();

    // Build the router from our api/ routes.
    var router = mer.Router.fromGenerated(allocator, @import("routes"));
    defer router.deinit();

    // Register the SSE /events raw handler (checked before routing).
    const raw_handler = mer.RawHandler{
        .ctx = @ptrCast(rt),
        .callback = &backend.handleEvents,
    };

    log.info("codegraff-gui native — {s} v{s} ({s}, static={s})", .{
        app_manifest.display_name,
        app_manifest.version,
        app_manifest.server_mode,
        app_manifest.static_dir orelse "public",
    });
    try native.Shell.run(allocator, app_manifest, &router, .{
        .raw_handler = &raw_handler,
    });
}

fn bundleResourcePath(allocator: std.mem.Allocator, exe_path: []const u8, resource_name: []const u8) ![]const u8 {
    const marker = "/Contents/MacOS/";
    const idx = std.mem.lastIndexOf(u8, exe_path, marker) orelse return error.NotAppBundle;
    return std.fmt.allocPrint(allocator, "{s}/Contents/Resources/{s}", .{ exe_path[0..idx], resource_name });
}
