// build.zig — codegraff-zig GUI native app (merjs consumer).
//
// Builds the native desktop shell: a merjs HTTP server (serving the Vite-built
// React SPA from dist/ + api/ backend routes + SSE /events) hosted in a system
// WKWebView. The React frontend (src/) is unchanged; only its runtime host
// changes from Tauri to merjs.
//
//   zig build native       # dev: run the shell (serves dist/)
//   zig build native-build # prod: build the binary
//   zig build package      # bundle as Codegraff.app
//
// Prereq: `bun run build` produces dist/ (the React SPA).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const merjs = b.dependency("merjs", .{
        .target = target,
        .optimize = optimize,
    });
    const mer_mod = merjs.module("mer");
    const runtime_mod = merjs.module("runtime");

    // native/main.zig — shell entry point.
    const native_mod = b.createModule(.{
        .root_source_file = b.path("native/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_mod.addImport("mer", mer_mod);
    native_mod.addImport("runtime", runtime_mod);

    // manifest — mer.app.zon (comptime config for the shell).
    const manifest_mod = b.createModule(.{
        .root_source_file = b.path("mer.app.zon"),
    });
    native_mod.addImport("manifest", manifest_mod);

    // Backend runtime module (the port of runtime/simple.rs).
    const backend_mod = b.createModule(.{
        .root_source_file = b.path("src-backend/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_mod.addImport("mer", mer_mod);
    backend_mod.addImport("runtime", runtime_mod);
    native_mod.addImport("backend", backend_mod);

    // routes — the app's route table. We have api/ backend routes only (no SSR
    // pages; the React SPA owns client rendering). Wire each api/*.zig as a
    // named import on the routes module, then add routes.zig as "routes".
    const routes_mod = b.createModule(.{
        .root_source_file = b.path("routes.zig"),
    });
    routes_mod.addImport("mer", mer_mod);
    routes_mod.addImport("backend", backend_mod);
    // Scan api/ and add each .zig as "api/<name>".
    addApiModules(b, routes_mod, mer_mod, runtime_mod, backend_mod, "api");
    native_mod.addImport("routes", routes_mod);

    // macOS frameworks for the WKWebView shell.
    native_mod.linkFramework("AppKit", .{});
    native_mod.linkFramework("WebKit", .{});
    native_mod.linkFramework("Foundation", .{});
    native_mod.link_libc = true;

    const exe = b.addExecutable(.{ .name = "codegraff-gui", .root_module = native_mod });
    b.installArtifact(exe);

    // `native` — run (dev).
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("native", "Run the codegraff GUI native shell");
    run_step.dependOn(&run_cmd.step);

    // `native-build` — install only (prod).
    const build_step = b.step("native-build", "Build the native shell binary (prod)");
    build_step.dependOn(b.getInstallStep());

    // `package` — .app bundle with manifest-driven Info.plist.
    const app_zon = @import("mer.app.zon");
    const pkg_name = b.fmt("{s}.app", .{app_zon.display_name});
    const plist_xml = b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key>    <string>codegraff-gui</string>
        \\  <key>CFBundleIdentifier</key>    <string>{s}</string>
        \\  <key>CFBundleName</key>          <string>{s}</string>
        \\  <key>CFBundleVersion</key>       <string>{s}</string>
        \\  <key>CFBundleIconFile</key>      <string>icon.icns</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  <key>NSPrincipalClass</key>      <string>NSApplication</string>
        \\</dict>
        \\</plist>
    , .{ app_zon.id, app_zon.display_name, app_zon.version });
    const plist = b.addWriteFile(b.fmt("{s}/Contents/Info.plist", .{pkg_name}), plist_xml);
    const pkg_bin = b.addInstallFile(
        exe.getEmittedBin(),
        b.fmt("{s}/Contents/MacOS/codegraff-gui", .{pkg_name}),
    );
    pkg_bin.step.dependOn(b.getInstallStep());
    const clean_pkg = b.addSystemCommand(&.{
        "rm",
        "-rf",
        b.getInstallPath(.prefix, pkg_name),
    });
    const pkg_icon = b.addInstallFile(
        b.path("src-tauri/icons/icon.icns"),
        b.fmt("{s}/Contents/Resources/icon.icns", .{pkg_name}),
    );
    const pkg_dist = b.addInstallDirectory(.{
        .source_dir = b.path("dist"),
        .install_dir = .prefix,
        .install_subdir = b.fmt("{s}/Contents/Resources/dist", .{pkg_name}),
    });
    const pkg_plist = b.addInstallDirectory(.{
        .source_dir = plist.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "",
    });
    const package_step = b.step("package", "Package the GUI as a .app bundle (macOS)");
    pkg_bin.step.dependOn(&clean_pkg.step);
    pkg_icon.step.dependOn(&clean_pkg.step);
    pkg_dist.step.dependOn(&clean_pkg.step);
    pkg_plist.step.dependOn(&clean_pkg.step);
    package_step.dependOn(&pkg_bin.step);
    package_step.dependOn(&pkg_icon.step);
    package_step.dependOn(&pkg_dist.step);
    package_step.dependOn(&pkg_plist.step);
}

/// Scan `dir/` for *.zig files and add each as a named module "api/<name>"
/// on `mod`, with `mer` wired so route files can `@import("mer")`.
fn addApiModules(
    b: *std.Build,
    mod: *std.Build.Module,
    mer_mod: *std.Build.Module,
    runtime_mod: *std.Build.Module,
    backend_mod: *std.Build.Module,
    dir: []const u8,
) void {
    var d = std.Io.Dir.cwd().openDir(b.graph.io, dir, .{ .iterate = true }) catch return;
    defer d.close(b.graph.io);
    var walker = d.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const file_path = b.fmt("{s}/{s}", .{ dir, entry.path });
        const import_name = b.fmt("api/{s}", .{entry.path[0 .. entry.path.len - 4]});
        const route_mod = b.createModule(.{ .root_source_file = b.path(file_path) });
        route_mod.addImport("mer", mer_mod);
        route_mod.addImport("runtime", runtime_mod);
        route_mod.addImport("backend", backend_mod);
        mod.addImport(import_name, route_mod);
    }
}
