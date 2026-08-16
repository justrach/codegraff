const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lean_release = optimize == .ReleaseFast or optimize == .ReleaseSmall;

    // `--version` string: stamped from `git describe` at build time so every
    // binary says which commit built it; `-Dversion=X.Y.Z` overrides (the
    // release workflow passes the tag).
    const version = b.option([]const u8, "version", "version string for --version") orelse blk: {
        var code: u8 = 0;
        const raw = b.runAllowFail(
            &.{ "git", "-C", ".", "describe", "--tags", "--always", "--dirty" },
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
            .strip = lean_release,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    // zigzag: the TUI framework backing the `graff repl` subcommand (and the
    // standalone graff-repl exe below). The repo's first dependency.
    const zigzag = b.dependency("zigzag", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("TUI/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tui", tui_mod);
    const install_graff = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_graff.step);
    const graff_step = b.step("graff", "Build and install only the release CLI");
    graff_step.dependOn(&install_graff.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install_graff.step);
    const run_step = b.step("run", "Run the harness");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — unit tests live in src/main.zig `test "..." {}` blocks.
    // `-Dtest-filter="<text>"` (repeatable) narrows the run to the tests whose
    // name contains that text. scripts/eval-tier1.sh uses it to prove the named
    // goal/loop/todo invariants still run — a test whose module fell out of the
    // test root exists in the source but never executes.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains this text (repeatable)",
    ) orelse &[_][]const u8{};
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    unit_tests.root_module.addOptions("build_options", opts);
    unit_tests.root_module.addImport("zigzag", zigzag.module("zigzag"));
    unit_tests.root_module.addImport("tui", tui_mod);
    // spec/ fixtures live outside src/; importing them here makes @embedFile
    // legal and rebuilds the suite when the exported semantics change.
    unit_tests.root_module.addAnonymousImport("spec_tool_catalog", .{ .root_source_file = b.path("spec/kernels/tool_catalog.json") });
    unit_tests.root_module.addAnonymousImport("spec_transport", .{ .root_source_file = b.path("spec/kernels/transport.json") });
    unit_tests.root_module.addAnonymousImport("spec_providers", .{ .root_source_file = b.path("spec/kernels/providers.json") });
    unit_tests.root_module.addAnonymousImport("spec_goal_loop", .{ .root_source_file = b.path("spec/kernels/goal_loop.json") });
    unit_tests.root_module.addAnonymousImport("spec_path_confine", .{ .root_source_file = b.path("spec/kernels/path_confine.json") });
    unit_tests.root_module.addAnonymousImport("spec_shape", .{ .root_source_file = b.path("spec/kernels/shape.json") });
    unit_tests.root_module.addAnonymousImport("spec_score", .{ .root_source_file = b.path("spec/kernels/score.json") });
    unit_tests.root_module.addAnonymousImport("spec_bash_policy", .{ .root_source_file = b.path("spec/kernels/bash_policy.json") });
    unit_tests.root_module.addAnonymousImport("spec_structured_output", .{ .root_source_file = b.path("spec/kernels/structured_output.json") });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Learning kit: the adapter/suite files `graff learn init` materializes
    // into a workspace so zero-configuration learning needs no repo checkout.
    // Embedded by name (src/learn_assets.zig `@embedFile`s these imports).
    for ([_]struct { import: []const u8, path: []const u8 }{
        .{ .import = "learn_kit_mutator", .path = "examples/learn_graff_mutator.py" },
        .{ .import = "learn_kit_evaluator", .path = "examples/learn_graff_evaluator.py" },
        .{ .import = "learn_kit_case", .path = "examples/learn_graff_case.py" },
        .{ .import = "learn_kit_behavior", .path = "examples/learn_behavior_metrics.py" },
        .{ .import = "learn_kit_suites", .path = "examples/learn_graff_suites.py" },
        .{ .import = "learn_kit_generate", .path = "examples/learn_generate_suites.py" },
        .{ .import = "learn_kit_scorer", .path = "scripts/score_run.py" },
    }) |asset| {
        exe.root_module.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
        unit_tests.root_module.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
    }

    // Bundled skills: SKILL.md playbooks compiled into every binary (embedded
    // by name in src/skill_docs.zig), so a fresh install already knows how to
    // author more skills and how to change this workspace's MCP servers.
    for ([_]struct { import: []const u8, path: []const u8 }{
        .{ .import = "skill_doc_creator", .path = "assets/skills/skill-creator.md" },
        .{ .import = "skill_doc_mcp_config", .path = "assets/skills/mcp-config.md" },
    }) |asset| {
        exe.root_module.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
        unit_tests.root_module.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
    }

    // --- spike (branch: spike/zigzag-repl): zigzag-based REPL ---
    // Also reachable as the `graff repl` subcommand of the main binary (see
    // src/main.zig). This standalone exe + `repl-test` step are kept for
    // isolated builds / unit tests. `zig build repl`, `zig build repl-test`.

    const repl_exe = b.addExecutable(.{
        .name = "graff-repl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/repl.zig"),
            .target = target,
            .optimize = optimize,
            .strip = lean_release,
        }),
    });
    repl_exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
    b.installArtifact(repl_exe);

    const repl_run = b.addRunArtifact(repl_exe);
    repl_run.step.dependOn(b.getInstallStep());
    const repl_step = b.step("repl", "Run the zigzag REPL spike");
    repl_step.dependOn(&repl_run.step);

    const repl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/repl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    repl_tests.root_module.addImport("zigzag", zigzag.module("zigzag"));
    const repl_test_step = b.step("repl-test", "Run zigzag REPL unit tests");
    repl_test_step.dependOn(&b.addRunArtifact(repl_tests).step);

    const tui_exe = b.addExecutable(.{
        .name = "graff-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("TUI/root.zig"),
            .target = target,
            .optimize = optimize,
            .strip = lean_release,
        }),
    });
    b.installArtifact(tui_exe);

    const tui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("TUI/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tui_tests.root_module.addAnonymousImport("spec_terminal_modes", .{ .root_source_file = b.path("spec/kernels/terminal_modes.json") });

    const tui_test_step = b.step("tui-test", "Run fullscreen TUI unit tests");
    tui_test_step.dependOn(&b.addRunArtifact(tui_tests).step);
}
