const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Every release mode ships stripped; ReleaseSafe is the shipped one.
    const lean_release = optimize != .debug;

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
    // `graff learn` (local policy learning) and its embedded Python kit. Dev
    // builds keep it so CI exercises it; release builds leave it out.
    const learn = b.option(bool, "learn", "include `graff learn` local policy learning (default true)") orelse true;
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOption([]const u8, "telemetry_endpoint", telemetry_endpoint);
    opts.addOption(bool, "learn", learn);

    // Release binaries ship without unwind tables or frame pointers: they are
    // stripped, so a panic can't print a useful trace anyway. On Windows only
    // graff's module drops them: the root's setting also builds the MinGW
    // startup code, which registers SEH handlers and needs its tables.
    const no_unwind = lean_release and target.result.os.tag != .windows;
    // graff's own code is its own module so it keeps the requested build mode
    // (ReleaseSafe checks overflow, bounds and union tags). The root module
    // only forwards to it; std and other generic library code follow the root,
    // which a ReleaseSafe release builds for size.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = lean_release,
        // Linux cross-builds (x86_64-linux for in-container evals) must say
        // libc explicitly; macOS resolves it implicitly and never notices.
        .link_libc = true,
        .unwind_tables = if (lean_release) .none else null,
        .omit_frame_pointer = if (lean_release) true else null,
        .error_tracing = if (lean_release) false else null,
    });
    const exe = b.addExecutable(.{
        .name = "graff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entry.zig"),
            .target = target,
            .optimize = if (optimize == .safe) .small else optimize,
            .strip = lean_release,
            .link_libc = true,
            .unwind_tables = if (no_unwind) .none else null,
            .omit_frame_pointer = if (lean_release) true else null,
        }),
    });
    exe.root_module.addImport("graff", app_mod);
    app_mod.addOptions("build_options", opts);
    const accord_dep = b.dependency("accord", .{ .target = target, .optimize = optimize });
    const accord_mod = accord_dep.module("accord");
    app_mod.addImport("accord", accord_mod);
    const http_zig_dep = b.dependency("http_zig", .{ .target = target, .optimize = optimize });
    const http_zig_mod = http_zig_dep.module("http_zig");
    app_mod.addImport("http_zig", http_zig_mod);
    // Shared model-ranking module used by the line-REPL picker.
    const models_rank_mod = b.createModule(.{
        .root_source_file = b.path("src/models_rank.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("models_rank", models_rank_mod);
    // Shared nearest-command speller for the REPL/ACP catalog.
    const slash_suggest_mod = b.createModule(.{
        .root_source_file = b.path("src/slash_suggest.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("slash_suggest", slash_suggest_mod);
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
            .link_libc = true, // workspace_switch reaches std.c.getcwd (#721); same as the exe
        }),
        .filters = test_filters,
    });
    unit_tests.root_module.addOptions("build_options", opts);
    unit_tests.root_module.addImport("accord", accord_mod);
    unit_tests.root_module.addImport("http_zig", http_zig_mod);
    unit_tests.root_module.addImport("models_rank", models_rank_mod);
    unit_tests.root_module.addImport("slash_suggest", slash_suggest_mod);
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
    unit_tests.root_module.addAnonymousImport("spec_prompt_cache", .{ .root_source_file = b.path("spec/kernels/prompt_cache.json") });
    unit_tests.root_module.addAnonymousImport("spec_prompt_prefix", .{ .root_source_file = b.path("spec/kernels/prompt_prefix.json") });
    unit_tests.root_module.addAnonymousImport("spec_prompt_stable", .{ .root_source_file = b.path("spec/kernels/prompt_stable.json") });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit and subprocess integration tests");
    test_step.dependOn(&run_tests.step);
    // Reachability only needs the binary. Running the suite here as well made
    // pre-push spend its 600s budget before the tests check started.
    const test_bin = b.step("test-bin", "Compile unit tests without running them");
    test_bin.dependOn(&unit_tests.step);
    // The working loop: the unit binary alone, without the integration
    // scripts `test` adds below. `-Dtest-filter` narrows it to named tests.
    const unit_step = b.step("unit", "Run only the unit tests (-Dtest-filter narrows them)");
    unit_step.dependOn(&run_tests.step);
    const acp_preauth_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-preauth.py" });
    acp_preauth_test.addArtifactArg(exe);
    test_step.dependOn(&acp_preauth_test.step);
    const issue_acp_test = b.addSystemCommand(&.{ "python3", "scripts/test-issue-acp.py" });
    issue_acp_test.addArtifactArg(exe);
    test_step.dependOn(&issue_acp_test.step);
    const acp_goal_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-goal.py" });
    acp_goal_test.addArtifactArg(exe);
    test_step.dependOn(&acp_goal_test.step);
    const acp_meta_status_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-meta-tool-status.py" });
    acp_meta_status_test.addArtifactArg(exe);
    test_step.dependOn(&acp_meta_status_test.step);
    const acp_yield_once_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-yield-once.py" });
    acp_yield_once_test.addArtifactArg(exe);
    test_step.dependOn(&acp_yield_once_test.step);
    const acp_startup_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-startup.py" });
    acp_startup_test.addArtifactArg(exe);
    test_step.dependOn(&acp_startup_test.step);
    const acp_harness_room_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-harness-room.py" });
    acp_harness_room_test.addArtifactArg(exe);
    test_step.dependOn(&acp_harness_room_test.step);
    const usage_trace_test = b.addSystemCommand(&.{ "python3", "scripts/test-usage-trace.py" });
    usage_trace_test.addArtifactArg(exe);
    test_step.dependOn(&usage_trace_test.step);
    const claude_agent_test = b.addSystemCommand(&.{ "python3", "scripts/test-claude-agent.py" });
    claude_agent_test.addArtifactArg(exe);
    test_step.dependOn(&claude_agent_test.step);
    const acp_view_meta_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-view-meta.py" });
    acp_view_meta_test.addArtifactArg(exe);
    test_step.dependOn(&acp_view_meta_test.step);
    const acp_ask_user_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-ask-user.py" });
    acp_ask_user_test.addArtifactArg(exe);
    test_step.dependOn(&acp_ask_user_test.step);
    const mcp_client_spec_test = b.addSystemCommand(&.{ "python3", "scripts/test-mcp-client-spec.py" });
    mcp_client_spec_test.addArtifactArg(exe);
    test_step.dependOn(&mcp_client_spec_test.step);
    const mcp_shared_test = b.addSystemCommand(&.{ "python3", "scripts/test-mcp-shared.py" });
    mcp_shared_test.addArtifactArg(exe);
    test_step.dependOn(&mcp_shared_test.step);
    const mcp_lazy_test = b.addSystemCommand(&.{ "python3", "scripts/test-mcp-lazy.py" });
    mcp_lazy_test.addArtifactArg(exe);
    test_step.dependOn(&mcp_lazy_test.step);
    const mcp_async_test = b.addSystemCommand(&.{ "python3", "scripts/test-mcp-async-start.py" });
    mcp_async_test.addArtifactArg(exe);
    test_step.dependOn(&mcp_async_test.step);
    const mcp_add_test = b.addSystemCommand(&.{ "python3", "scripts/test-mcp-add.py" });
    mcp_add_test.addArtifactArg(exe);
    test_step.dependOn(&mcp_add_test.step);
    const mcp_status_test = b.addSystemCommand(&.{ "python3", "scripts/test-mcp-status.py" });
    mcp_status_test.addArtifactArg(exe);
    test_step.dependOn(&mcp_status_test.step);
    const acp_v2_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-v2.py" });
    acp_v2_test.addArtifactArg(exe);
    test_step.dependOn(&acp_v2_test.step);
    const acp_effort_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-effort-config.py" });
    acp_effort_test.addArtifactArg(exe);
    test_step.dependOn(&acp_effort_test.step);
    const acp_agent_wait_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-agent-output-wait.py" });
    acp_agent_wait_test.addArtifactArg(exe);
    test_step.dependOn(&acp_agent_wait_test.step);
    const acp_child_update_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-subagent-update.py" });
    acp_child_update_test.addArtifactArg(exe);
    test_step.dependOn(&acp_child_update_test.step);
    const acp_background_child_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-background-subagent.py" });
    acp_background_child_test.addArtifactArg(exe);
    test_step.dependOn(&acp_background_child_test.step);
    const repl_background_wait_test = b.addSystemCommand(&.{ "python3", "scripts/test-repl-background-wait.py" });
    repl_background_wait_test.addArtifactArg(exe);
    test_step.dependOn(&repl_background_wait_test.step);
    const shell_wait_todo_test = b.addSystemCommand(&.{ "python3", "scripts/test-shell-wait-and-todo-reply.py" });
    shell_wait_todo_test.addArtifactArg(exe);
    test_step.dependOn(&shell_wait_todo_test.step);
    const workflow_isolation_test = b.addSystemCommand(&.{ "python3", "scripts/test-workflow-isolation.py" });
    workflow_isolation_test.addArtifactArg(exe);
    test_step.dependOn(&workflow_isolation_test.step);
    const workspace_lifecycle_test = b.addSystemCommand(&.{ "python3", "scripts/test-workspace-lifecycle.py" });
    workspace_lifecycle_test.addArtifactArg(exe);
    test_step.dependOn(&workspace_lifecycle_test.step);
    const agents_prepare_test = b.addSystemCommand(&.{ "python3", "scripts/test-agents-prepare.py" });
    agents_prepare_test.addArtifactArg(exe);
    test_step.dependOn(&agents_prepare_test.step);
    const acp_workspace_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-workspace.py" });
    acp_workspace_test.addArtifactArg(exe);
    test_step.dependOn(&acp_workspace_test.step);
    const acp_images_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-images.py" });
    acp_images_test.addArtifactArg(exe);
    test_step.dependOn(&acp_images_test.step);
    const acp_slash_typo_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-slash-typo.py" });
    acp_slash_typo_test.addArtifactArg(exe);
    test_step.dependOn(&acp_slash_typo_test.step);
    const acp_compaction_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-compaction.py" });
    acp_compaction_test.addArtifactArg(exe);
    test_step.dependOn(&acp_compaction_test.step);
    const acp_stream_drop_test = b.addSystemCommand(&.{ "python3", "scripts/test-acp-stream-drop.py" });
    acp_stream_drop_test.addArtifactArg(exe);
    test_step.dependOn(&acp_stream_drop_test.step);
    const retry_cancellation_test = b.addSystemCommand(&.{ "python3", "scripts/test-retry-cancellation.py" });
    retry_cancellation_test.addArtifactArg(exe);
    test_step.dependOn(&retry_cancellation_test.step);
    const offline_recovery_test = b.addSystemCommand(&.{ "python3", "scripts/test-offline-recovery.py" });
    offline_recovery_test.addArtifactArg(exe);
    test_step.dependOn(&offline_recovery_test.step);
    const run_tool_budget_test = b.addSystemCommand(&.{ "python3", "scripts/test-run-tool-budget.py" });
    run_tool_budget_test.addArtifactArg(exe);
    test_step.dependOn(&run_tool_budget_test.step);
    const subagent_resume_test = b.addSystemCommand(&.{ "python3", "scripts/test-subagent-resume.py" });
    subagent_resume_test.addArtifactArg(exe);
    test_step.dependOn(&subagent_resume_test.step);
    const subagent_fork_test = b.addSystemCommand(&.{ "python3", "scripts/test-subagent-fork.py" });
    subagent_fork_test.addArtifactArg(exe);
    test_step.dependOn(&subagent_fork_test.step);
    const workflow_synthesis_test = b.addSystemCommand(&.{ "python3", "scripts/test-workflow-synthesis.py" });
    workflow_synthesis_test.addArtifactArg(exe);
    test_step.dependOn(&workflow_synthesis_test.step);
    const learn_formal_test = b.addSystemCommand(&.{ "python3", "tests/learn_formal_e2e.py", "--graff" });
    learn_formal_test.addArtifactArg(exe);
    test_step.dependOn(&learn_formal_test.step);
    test_step.dependOn(&b.addSystemCommand(&.{ "python3", "graff-evals/test_measurement.py" }).step);
    test_step.dependOn(&b.addSystemCommand(&.{ "python3", "scripts/test-eval-cache-affinity.py" }).step);

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
        app_mod.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
        unit_tests.root_module.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
    }

    // Text only needed at run time ships gzipped; callers inflate it with
    // update_archive.gunzip. Imported as "<name>.gz".
    const gzip_asset = b.addExecutable(.{
        .name = "gzip_asset",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/gzip_asset.zig"),
            .target = b.graph.host,
        }),
    });
    for ([_]struct { import: []const u8, path: []const u8 }{
        .{ .import = "mcp_installer.gz", .path = "scripts/install-mcp.py" },
        .{ .import = "chatgpt_callback.gz", .path = "src/oauth_page/chatgpt_callback.html" },
        .{ .import = "mcp_app_host.gz", .path = "src/mcp_app_host.html" },
        .{ .import = "mcp_task_app.gz", .path = "src/mcp_task_app.html" },
        .{ .import = "ui_theme.gz", .path = "src/ui_theme.css" },
    }) |asset| {
        const gzip_run = b.addRunArtifact(gzip_asset);
        gzip_run.addFileArg(b.path(asset.path));
        const gz = gzip_run.addOutputFileArg(asset.import);
        app_mod.addAnonymousImport(asset.import, .{ .root_source_file = gz });
        unit_tests.root_module.addAnonymousImport(asset.import, .{ .root_source_file = gz });
    }

    // Evaluate the CLI's Zig text constants on the host, including the learn
    // conditional, then reuse the same compressor as the other runtime assets.
    const cli_source = b.createModule(.{
        .root_source_file = b.path("src/cli_text_source.zig"),
        .target = b.graph.host,
    });
    cli_source.addOptions("build_options", opts);
    const cli_text = b.addExecutable(.{
        .name = "cli_text",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/cli_text.zig"),
            .target = b.graph.host,
        }),
    });
    cli_text.root_module.addImport("cli_text_source", cli_source);
    const text_run = b.addRunArtifact(cli_text);
    const help_text = text_run.addOutputFileArg("cli_help.txt");
    const changelog_text = text_run.addOutputFileArg("cli_changelog.txt");
    for ([_]struct { name: []const u8, text: std.Build.LazyPath }{
        .{ .name = "cli_help.gz", .text = help_text },
        .{ .name = "cli_changelog.gz", .text = changelog_text },
    }) |asset| {
        const gzip_run = b.addRunArtifact(gzip_asset);
        gzip_run.addFileArg(asset.text);
        const gz = gzip_run.addOutputFileArg(asset.name);
        app_mod.addAnonymousImport(asset.name, .{ .root_source_file = gz });
        unit_tests.root_module.addAnonymousImport(asset.name, .{ .root_source_file = gz });
    }

    // Bundled skills: SKILL.md playbooks compiled into every binary (embedded
    // by name in src/skill_docs.zig), so a fresh install already knows how to
    // author more skills and how to change this workspace's MCP servers.
    for ([_]struct { import: []const u8, path: []const u8 }{
        .{ .import = "skill_doc_creator", .path = "assets/skills/skill-creator.md" },
        .{ .import = "skill_doc_mcp_config", .path = "assets/skills/mcp-config.md" },
        .{ .import = "skill_doc_mcp", .path = "assets/skills/mcp.md" },
        .{ .import = "skill_doc_jspace", .path = "assets/skills/jspace.md" },
        .{ .import = "skill_doc_workspace", .path = "assets/skills/workspace.md" },
    }) |asset| {
        app_mod.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
        unit_tests.root_module.addAnonymousImport(asset.import, .{ .root_source_file = b.path(asset.path) });
        const gzip_run = b.addRunArtifact(gzip_asset);
        gzip_run.addFileArg(b.path(asset.path));
        const gzip_import = b.fmt("{s}.gz", .{asset.import});
        const gz = gzip_run.addOutputFileArg(gzip_import);
        app_mod.addAnonymousImport(gzip_import, .{ .root_source_file = gz });
        unit_tests.root_module.addAnonymousImport(gzip_import, .{ .root_source_file = gz });
    }

    const external_tui_test = b.addSystemCommand(&.{ "python3", "scripts/test-external-tui.py" });
    external_tui_test.addArtifactArg(exe);
    test_step.dependOn(&external_tui_test.step);

    // In-process ACP (fx-shaped embed). Off the default install so the
    // tagged CLI cut does not grow a .so / .wasm. `zig build libgraff`
    // and `zig build -Dwasm-surface=core`.
    const libgraff = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "graff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/libgraff.zig"),
            .target = target,
            .optimize = optimize,
            .strip = lean_release,
        }),
    });
    const libgraff_step = b.step("libgraff", "Build the in-process ACP shared library");
    libgraff_step.dependOn(&b.addInstallArtifact(libgraff, .{}).step);

    _ = b.option([]const u8, "wasm-surface", "wasm surface: core (use `zig build wasm-core`)");
    // Pinned ReleaseSmall regardless of the global optimize: the wasm surface
    // ships in @codegraff/sdk for JS hosts, so size is the axis that matters
    // (vercel-labs/fx pins it the same way). -Doptimize still overrides.
    const wasm = b.addExecutable(.{
        .name = "graff-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_core_main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = if (optimize == .debug) .small else optimize,
            .strip = true,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm-core", "Build graff-core.wasm (in-process ACP)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // Experimental JSPI host: shared chat step, with model/tools supplied by
    // the Worker. No native Agent I/O or the echo-only ACP embedding surface.
    const worker = b.addExecutable(.{
        .name = "graff-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_worker_main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = if (optimize == .debug) .small else optimize,
            .strip = true,
        }),
    });
    worker.entry = .disabled;
    worker.rdynamic = true;
    const worker_step = b.step("wasm-worker", "Build the experimental Worker-native Graff core");
    worker_step.dependOn(&b.addInstallArtifact(worker, .{}).step);
}
