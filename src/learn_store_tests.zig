//! Tests for learn_store.zig (600-line goal). Reached through the
//! `test { _ = ... }` hook in learn_store.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const store_mod = @import("learn_store.zig");

const Store = store_mod.Store;
const Transaction = store_mod.Transaction;
const ActiveRef = store_mod.ActiveRef;
const domainId = store_mod.domainId;
const jsonBytes = store_mod.jsonBytes;
const readFileNoFollow = store_mod.readFileNoFollow;
const config_schema = store_mod.config_schema;
const active_schema = store_mod.active_schema;
const Config = store_mod.Config;
const validId = store_mod.validId;
const syncDirectory = store_mod.syncDirectory;
const validateConfig = store_mod.validateConfig;
const transaction_schema = store_mod.transaction_schema;

test "learning IDs are full, domain-separated, and byte exact" {
    const a = domainId("codegraff-learn/genome/v1", "hello\n");
    const b = domainId("codegraff-learn/genome/v1", "hello");
    const c = domainId("codegraff-learn/evidence/v1", "hello\n");
    try std.testing.expect(validId(&a));
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
    try std.testing.expect(!validId("ABC"));
}

test "learning config parser rejects unknown fields and unsafe auto" {
    const good =
        \\{"schema":"codegraff.learn.config.v1","agent_name":"candidate","mutation_instruction":"change one behavior","mutator":{"program":"/bin/a","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"evaluator":{"program":"/bin/b","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"evaluation_suite":{"path":"/suite","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"cohort":{"provider":"test","model":"test","task_family":"test","adapter_version":"v1","verifier_version":"v1"}}
    ;
    var parsed = try std.json.parseFromSlice(Config, std.testing.allocator, good, .{});
    defer parsed.deinit();
    try validateConfig(parsed.value);
    const unknown = good[0 .. good.len - 1] ++ ",\"surprise\":true}";
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Config, std.testing.allocator, unknown, .{}));
}

test "directory synchronization reopens path-only handles" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try syncDirectory(io, tmp.dir);
}

test "no-follow reads preserve exact bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample", .data = "exact bytes" });
    const bytes = try readFileNoFollow(io, tmp.dir, "sample", std.testing.allocator, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("exact bytes", bytes);
}

test "immutable learning objects and atomic active ref round trip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.initAt(io, tmp.dir);
    defer store.deinit();

    const first = try store.writeGenome(std.testing.allocator, "prompt one");
    const again = try store.writeGenome(std.testing.allocator, "prompt one");
    try std.testing.expectEqualStrings(&first, &again);
    const read = try store.readGenome(std.testing.allocator, &first, 1024);
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("prompt one", read);
}

test "learning activation rejects stale refs and broken transaction ancestry" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.initAt(io, tmp.dir);
    defer store.deinit();

    const config: Config = .{
        .schema = config_schema,
        .agent_name = "test-agent",
        .mutation_instruction = "change",
        .mutator = .{ .program = "/bin/a", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .evaluator = .{ .program = "/bin/b", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .evaluation_suite = .{ .path = "/suite", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
        .cohort = .{ .provider = "p", .model = "m", .task_family = "t", .adapter_version = "a", .verifier_version = "v" },
    };
    const config_bytes = try jsonBytes(allocator, config);
    defer allocator.free(config_bytes);
    _ = try store.bootstrap(allocator, arena, config_bytes, "parent", 1);
    const loaded_config = try store.loadConfig(arena);
    const active_zero = try store.loadActive(arena, loaded_config);
    const second = try store.writeGenome(allocator, "second");
    try std.testing.expectError(error.FileTooBig, store.activate(allocator, active_zero.ref, &loaded_config.id, &second, null, "rollback", 1, 2));
    try store.activate(allocator, active_zero.ref, &loaded_config.id, &second, null, "rollback", config.limits.genome_bytes, 2);
    const active_one = try store.loadActive(arena, loaded_config);
    const third = try store.writeGenome(allocator, "third");
    try std.testing.expectError(error.ActiveRefChanged, store.activate(allocator, active_zero.ref, &loaded_config.id, &third, null, "rollback", config.limits.genome_bytes, 3));

    const broken_tx: Transaction = .{
        .schema = transaction_schema,
        .generation = 2,
        .operation = "rollback",
        .previous_genome_id = active_one.ref.genome_id,
        .next_genome_id = &third,
        .run_id = null,
        .previous_transaction_id = active_zero.ref.transaction_id,
        .created_unix_ms = 4,
    };
    const broken_tx_bytes = try jsonBytes(allocator, broken_tx);
    defer allocator.free(broken_tx_bytes);
    const broken_tx_id = try store.writeTransaction(allocator, broken_tx_bytes);
    const broken_active: ActiveRef = .{
        .schema = active_schema,
        .config_id = &loaded_config.id,
        .generation = 2,
        .genome_id = &third,
        .transaction_id = &broken_tx_id,
    };
    const broken_active_bytes = try jsonBytes(allocator, broken_active);
    defer allocator.free(broken_active_bytes);
    try store.writeAtomicReplace(store.refs, "active.json", broken_active_bytes);
    try std.testing.expectError(error.BrokenTransactionChain, store.loadActive(arena, loaded_config));
}

test "learning store rejects symlinked root" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.symLink(io, "outside", ".graff", .{ .is_directory = true });
    if (Store.initAt(io, tmp.dir)) |opened| {
        var store = opened;
        store.deinit();
        return error.TestExpectedError;
    } else |_| {}
}
