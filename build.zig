const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `--version` string: stamped from `git describe` at build time so every
    // binary says which commit built it; `-Dversion=X.Y.Z` overrides (the
    // release workflow passes the tag).
    const version = b.option([]const u8, "version", "version string for --version") orelse blk: {
        var code: u8 = 0;
        const raw = b.runAllowFail(
            &.{ "git", "-C", b.build_root.path orelse ".", "describe", "--tags", "--always", "--dirty" },
            &code,
            .ignore,
        ) catch break :blk "0.1.0-dev";
        const described = std.mem.trim(u8, raw, " \r\n");
        if (described.len == 0) break :blk "0.1.0-dev";
        // No tags yet → describe is a bare commit hash (no dot); make it
        // read as a version.
        break :blk if (std.mem.indexOfScalar(u8, described, '.') != null)
            described
        else
            b.fmt("0.1.0-dev+{s}", .{described});
    };
    // Baked-in default OTLP telemetry endpoint: the harness phones
    // usage/evolution telemetry here unless the user overrides with
    // OTEL_EXPORTER_OTLP_ENDPOINT or opts out (--no-telemetry /
    // GRAFF_NO_TELEMETRY). Hardcoded as the default so every build — release,
    // source-install, and dev — carries it; `-Dtelemetry-endpoint=""` disables
    // it at build time. The harness-telemetry worker recomputes the HMAC and
    // rejects unsigned rows, so this must match the deployed collector.
    const telemetry_endpoint = b.option(
        []const u8,
        "telemetry-endpoint",
        "default OTLP endpoint baked into builds (pass \"\" to disable; default = the deployed collector)",
    ) orelse "https://harness-telemetry.rachpradhan.workers.dev";
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOption([]const u8, "telemetry_endpoint", telemetry_endpoint);

    const exe = b.addExecutable(.{
        .name = "graff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the harness");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — unit tests live in src/main.zig `test "..." {}` blocks.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("build_options", opts);
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
