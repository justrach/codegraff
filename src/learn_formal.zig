//! Optional, pinned model-check baseline for native prompt-policy learning.
//! The result concerns shared engine source, not the candidate prompt's behavior.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const store_mod = @import("learn_store.zig");
const jobs = @import("jobs.zig");
const util = @import("util.zig");

pub const evidence_schema = "codegraff.learn.formal-evidence.v1";
const check_schema = "codegraff.dgm.formal-check.v1";
const stdout_cap = 4096;
const stderr_cap = 4096;

pub const Evidence = struct {
    schema: []const u8 = evidence_schema,
    phase: []const u8,
    config_id: []const u8,
    trial_id: []const u8,
    candidate_prompt_sha256: []const u8,
    formal_identity_sha256: []const u8,
    checker_output_sha256: []const u8,
    binary_sha256: []const u8,
    formal_pin_sha256: []const u8,
    checker_sha256: []const u8,
    helper_sha256: []const u8,
};

fn validHash(value: []const u8) bool {
    return store_mod.validId(value);
}

fn promptHash(prompt: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(prompt, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn checkedString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = util.strFieldObj(obj, key) orelse return error.InvalidFormalCheckResult;
    if (!validHash(value)) return error.InvalidFormalCheckResult;
    return value;
}

fn parseResult(arena: Allocator, raw: []const u8, candidate_sha: []const u8, binary_sha: []const u8) !Evidence {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    if (parsed != .object or parsed.object.count() != 6 or
        !std.mem.eql(u8, util.strFieldObj(parsed.object, "schema") orelse "", check_schema))
        return error.InvalidFormalCheckResult;
    const ok = parsed.object.get("ok") orelse return error.InvalidFormalCheckResult;
    if (ok != .bool or !ok.bool) return error.InvalidFormalCheckResult;
    const got_candidate = try checkedString(parsed.object, "candidate_prompt_sha256");
    const got_binary = try checkedString(parsed.object, "binary_sha256");
    if (!std.mem.eql(u8, got_candidate, candidate_sha) or !std.mem.eql(u8, got_binary, binary_sha))
        return error.FormalCheckIdentityMismatch;
    return .{
        .phase = "",
        .config_id = "",
        .trial_id = "",
        .candidate_prompt_sha256 = got_candidate,
        .formal_identity_sha256 = try checkedString(parsed.object, "formal_identity_sha256"),
        .checker_output_sha256 = try checkedString(parsed.object, "checker_output_sha256"),
        .binary_sha256 = got_binary,
        .formal_pin_sha256 = "",
        .checker_sha256 = "",
        .helper_sha256 = "",
    };
}

fn binaryPin(arena: Allocator, io: Io, formal: store_mod.FormalCheck) !store_mod.PinnedFile {
    const bytes = try store_mod.readPinnedFileAlloc(io, arena, formal.pin, store_mod.max_config_bytes);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (parsed != .object) return error.InvalidFormalPin;
    const binary = parsed.object.get("binary") orelse return error.InvalidFormalPin;
    if (binary != .object) return error.InvalidFormalPin;
    const sha = util.strFieldObj(binary.object, "sha256") orelse return error.InvalidFormalPin;
    const path = util.strFieldObj(binary.object, "path") orelse return error.InvalidFormalPin;
    if (!validHash(sha) or !std.fs.path.isAbsolute(path)) return error.InvalidFormalPin;
    return .{ .path = path, .sha256 = sha };
}

fn matchesAdapter(program: store_mod.Program, binary: store_mod.PinnedFile) bool {
    var pinned = false;
    var passed = false;
    for (program.inputs) |input| {
        if (std.mem.eql(u8, input.path, binary.path) and std.mem.eql(u8, input.sha256, binary.sha256))
            pinned = true;
    }
    for (program.args) |arg| {
        if (std.mem.eql(u8, arg, binary.path)) passed = true;
    }
    return pinned and passed;
}

pub fn verifyBinaryBinding(arena: Allocator, io: Io, config: store_mod.Config) !void {
    const formal = config.formal_check orelse return;
    const binary = try binaryPin(arena, io, formal);
    if (!matchesAdapter(config.mutator, binary) or !matchesAdapter(config.evaluator, binary))
        return error.FormalBinaryMismatch;
}

fn check(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    formal: store_mod.FormalCheck,
    prompt: []const u8,
) !Evidence {
    const key_path = environ.get("GRAFF_SCORE_KEY_FILE") orelse return error.FormalSigningKeyRequired;
    if (!std.fs.path.isAbsolute(key_path)) return error.FormalSigningKeyRequired;
    if (formal.checker.args.len != 1 or formal.checker.inputs.len != 1)
        return error.InvalidFormalChecker;
    try store_mod.verifyProgram(io, formal.checker);
    try store_mod.verifyPinnedFile(io, formal.pin);
    const expected_binary = (try binaryPin(arena, io, formal)).sha256;
    const candidate_sha = promptHash(prompt);
    var child_env = std.process.Environ.Map.init(gpa);
    defer child_env.deinit();
    try child_env.put("PATH", "/usr/bin:/bin");
    try child_env.put("LANG", "C");
    try child_env.put("LC_ALL", "C");
    try child_env.put("GRAFF_SCORE_KEY_FILE", key_path);
    try child_env.put("PYTHONDONTWRITEBYTECODE", "1");
    const argv = [_][]const u8{
        formal.checker.program,
        formal.checker.args[0],
        "--check",
        formal.pin.path,
        "--candidate-sha256",
        &candidate_sha,
    };
    const run = try jobs.runCappedWithOptions(gpa, io, &argv, stdout_cap, stderr_cap, formal.timeout_ms, .{
        .environ_map = &child_env,
        .kill_process_tree = true,
    });
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    if (run.timed_out or run.cancelled) return error.FormalCheckTimedOut;
    if (run.stdout_truncated or run.stderr_truncated) return error.FormalCheckOutputTooLarge;
    if (run.term != .exited or run.term.exited != 0) return error.FormalCheckFailed;
    // The pin is checked after execution too. The external pin/helper is an
    // operator trust input; this detects drift, not adversarial transient swap.
    try store_mod.verifyProgram(io, formal.checker);
    try store_mod.verifyPinnedFile(io, formal.pin);
    var result = try parseResult(arena, run.stdout, &candidate_sha, expected_binary);
    result.formal_pin_sha256 = formal.pin.sha256;
    result.checker_sha256 = formal.checker.sha256;
    result.helper_sha256 = formal.checker.inputs[0].sha256;
    return result;
}

pub fn record(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store: *store_mod.Store,
    formal: store_mod.FormalCheck,
    config_id: []const u8,
    trial_id: []const u8,
    phase: []const u8,
    prompt: []const u8,
) ![]const u8 {
    if (!std.mem.eql(u8, phase, "admission") and !std.mem.eql(u8, phase, "selection"))
        return error.InvalidFormalPhase;
    var result = try check(gpa, arena, io, environ, formal, prompt);
    result.phase = phase;
    result.config_id = config_id;
    result.trial_id = trial_id;
    const bytes = try store_mod.jsonBytes(gpa, result);
    defer gpa.free(bytes);
    const id = try store.writeEvidence(gpa, bytes);
    return try arena.dupe(u8, &id);
}

pub fn verify(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store: *store_mod.Store,
    formal: store_mod.FormalCheck,
    evidence_id: []const u8,
    config_id: []const u8,
    trial_id: []const u8,
    phase: []const u8,
    prompt: []const u8,
) !void {
    if (formal.checker.args.len != 1 or formal.checker.inputs.len != 1)
        return error.InvalidFormalChecker;
    const bytes = try store.readEvidence(arena, evidence_id, store_mod.max_record_bytes);
    const saved = try std.json.parseFromSliceLeaky(Evidence, arena, bytes, .{});
    const expected_sha = promptHash(prompt);
    if (!std.mem.eql(u8, saved.schema, evidence_schema) or
        !std.mem.eql(u8, saved.phase, phase) or
        !std.mem.eql(u8, saved.config_id, config_id) or
        !std.mem.eql(u8, saved.trial_id, trial_id) or
        !std.mem.eql(u8, saved.candidate_prompt_sha256, &expected_sha) or
        !std.mem.eql(u8, saved.formal_pin_sha256, formal.pin.sha256) or
        !std.mem.eql(u8, saved.checker_sha256, formal.checker.sha256) or
        !std.mem.eql(u8, saved.helper_sha256, formal.checker.inputs[0].sha256) or
        !validHash(saved.formal_identity_sha256) or !validHash(saved.checker_output_sha256) or
        !validHash(saved.binary_sha256)) return error.FormalEvidenceMismatch;
    const fresh = try check(gpa, arena, io, environ, formal, prompt);
    // TLC output contains timestamps/seeds, so its output hash may differ on a
    // fresh run. The pinned identity, binary and candidate must match.
    if (!std.mem.eql(u8, saved.formal_identity_sha256, fresh.formal_identity_sha256) or
        !std.mem.eql(u8, saved.binary_sha256, fresh.binary_sha256))
        return error.FormalEvidenceMismatch;
}

test "formal helper result rejects false success and wrong candidate" {
    const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good = try std.fmt.allocPrint(arena, "{{\"schema\":\"{s}\",\"ok\":true,\"candidate_prompt_sha256\":\"{s}\",\"formal_identity_sha256\":\"{s}\",\"checker_output_sha256\":\"{s}\",\"binary_sha256\":\"{s}\"}}", .{ check_schema, a, a, a, b });
    _ = try parseResult(arena, good, a, b);
    try std.testing.expectError(error.FormalCheckIdentityMismatch, parseResult(arena, good, b, b));
    const false_success = try std.fmt.allocPrint(arena, "{{\"schema\":\"{s}\",\"ok\":false,\"candidate_prompt_sha256\":\"{s}\",\"formal_identity_sha256\":\"{s}\",\"checker_output_sha256\":\"{s}\",\"binary_sha256\":\"{s}\"}}", .{ check_schema, a, a, a, b });
    try std.testing.expectError(error.InvalidFormalCheckResult, parseResult(arena, false_success, a, b));
}

test "formal binary must be pinned and passed to both adapters" {
    const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const binary: store_mod.PinnedFile = .{ .path = "/opt/graff", .sha256 = a };
    const correct: store_mod.Program = .{
        .program = "/opt/adapter",
        .sha256 = b,
        .args = &.{"/opt/graff"},
        .inputs = &.{binary},
    };
    try std.testing.expect(matchesAdapter(correct, binary));
    var wrong = correct;
    wrong.args = &.{"/opt/other"};
    try std.testing.expect(!matchesAdapter(wrong, binary));
    wrong = correct;
    wrong.inputs = &.{.{ .path = "/opt/graff", .sha256 = b }};
    try std.testing.expect(!matchesAdapter(wrong, binary));
}

test "default configuration skips the optional formal checker" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const config: store_mod.Config = .{
        .schema = store_mod.config_schema,
        .agent_name = "candidate",
        .mutation_instruction = "change one behavior",
        .mutator = .{ .program = "/missing/mutator", .sha256 = hash },
        .evaluator = .{ .program = "/missing/evaluator", .sha256 = hash },
        .evaluation_suite = .{ .path = "/missing/suite", .sha256 = hash },
        .cohort = .{ .provider = "test", .model = "test", .task_family = "test", .adapter_version = "v1", .verifier_version = "v1" },
    };
    try verifyBinaryBinding(std.testing.allocator, std.testing.io, config);
}

test "pinned helper evidence is rechecked for resume and promotion contexts" {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const helper_path = try std.fmt.allocPrint(arena, "{s}/helper.sh", .{root});
    const pin_path = try std.fmt.allocPrint(arena, "{s}/pin.json", .{root});
    const key_path = try std.fmt.allocPrint(arena, "{s}/key", .{root});
    const binary_hash = try store_mod.hashFileNoFollow(io, "/bin/sh");
    const identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const script = try std.fmt.allocPrint(arena, "printf '{{\"schema\":\"{s}\",\"ok\":true,\"candidate_prompt_sha256\":\"%s\",\"formal_identity_sha256\":\"{s}\",\"checker_output_sha256\":\"{s}\",\"binary_sha256\":\"{s}\"}}\\n' \"$4\"\n", .{ check_schema, identity, identity, &binary_hash });
    {
        const file = try tmp.dir.createFile(io, "helper.sh", .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, script);
    }
    const pin_bytes = try std.fmt.allocPrint(arena, "{{\"binary\":{{\"path\":\"/bin/sh\",\"sha256\":\"{s}\"}}}}\n", .{&binary_hash});
    {
        const file = try tmp.dir.createFile(io, "pin.json", .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, pin_bytes);
    }
    {
        const file = try tmp.dir.createFile(io, "key", .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, "test key");
    }
    const helper_hash = store_mod.rawSha256(script);
    const pin_hash = store_mod.rawSha256(pin_bytes);
    const inputs = [_]store_mod.PinnedFile{.{ .path = helper_path, .sha256 = &helper_hash }};
    const formal: store_mod.FormalCheck = .{
        .checker = .{ .program = "/bin/sh", .sha256 = &binary_hash, .args = &.{helper_path}, .inputs = &inputs },
        .pin = .{ .path = pin_path, .sha256 = &pin_hash },
        .timeout_ms = 2000,
    };
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try std.testing.expectError(error.FormalSigningKeyRequired, check(gpa, arena, io, &env, formal, "parent prompt"));
    try env.put("GRAFF_SCORE_KEY_FILE", key_path);
    var store = try store_mod.Store.initAt(io, tmp.dir);
    defer store.deinit();
    const config_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const trial_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const admission = try record(gpa, arena, io, &env, &store, formal, config_id, trial_id, "admission", "parent prompt");
    try verify(gpa, arena, io, &env, &store, formal, admission, config_id, trial_id, "admission", "parent prompt");
    try std.testing.expectError(error.FormalEvidenceMismatch, verify(gpa, arena, io, &env, &store, formal, admission, config_id, trial_id, "admission", "changed parent"));
    try std.testing.expectError(error.FormalEvidenceMismatch, verify(gpa, arena, io, &env, &store, formal, admission, config_id, trial_id, "selection", "parent prompt"));
    const selection = try record(gpa, arena, io, &env, &store, formal, config_id, trial_id, "selection", "selected prompt");
    try verify(gpa, arena, io, &env, &store, formal, selection, config_id, trial_id, "selection", "selected prompt");
    try std.testing.expectError(error.FormalEvidenceMismatch, verify(gpa, arena, io, &env, &store, formal, selection, config_id, trial_id, "selection", "different selection"));
    const missing = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    try std.testing.expectError(error.FileNotFound, verify(gpa, arena, io, &env, &store, formal, missing, config_id, trial_id, "admission", "parent prompt"));

    const slow_script = "sleep 2\n";
    {
        const file = try tmp.dir.createFile(io, "helper.sh", .{ .truncate = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, slow_script);
    }
    const slow_hash = store_mod.rawSha256(slow_script);
    const slow_inputs = [_]store_mod.PinnedFile{.{ .path = helper_path, .sha256 = &slow_hash }};
    var slow_formal = formal;
    slow_formal.checker.inputs = &slow_inputs;
    slow_formal.timeout_ms = 50;
    try std.testing.expectError(error.FormalCheckTimedOut, check(gpa, arena, io, &env, slow_formal, "parent prompt"));
}
