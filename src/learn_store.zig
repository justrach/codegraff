//! Authoritative local storage for the prompt-policy learning engine.
//!
//! The legacy trajectory archive remains observability only. Learning state is
//! held in immutable, full-SHA-256-addressed objects below `.graff/learn`, and
//! the only mutable commit point is an atomically replaced active reference.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const config_schema = "codegraff.learn.config.v1";
pub const suite_schema = "codegraff.learn.suite.v1";
pub const active_schema = "codegraff.learn.active.v1";
pub const transaction_schema = "codegraff.learn.transaction.v1";
pub const version_bytes = "1\n";

pub const max_config_bytes: usize = 1 << 20;
pub const max_record_bytes: usize = 8 << 20;
pub const max_program_bytes: u64 = 128 << 20;
pub const max_suite_bytes: usize = 8 << 20;
pub const max_pairs: usize = 4096;

pub const PinnedFile = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Program = struct {
    program: []const u8,
    sha256: []const u8,
    args: []const []const u8 = &.{},
    inputs: []const PinnedFile = &.{},
    pass_env: []const []const u8 = &.{},
};

pub const Suite = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Limits = struct {
    genome_bytes: usize = 1 << 20,
    request_bytes: usize = 1 << 20,
    response_bytes: usize = 4 << 20,
    stdout_bytes: usize = 64 << 10,
    stderr_bytes: usize = 64 << 10,
    mutator_timeout_ms: u64 = 300_000,
    evaluator_timeout_ms: u64 = 1_800_000,
};

pub const Gate = struct {
    alpha_ppm: u32 = 50_000,
    minimum_delta_ppm: u32 = 50_000,
    minimum_pairs: usize = 20,
    default_candidates: usize = 1,
    default_repetitions: usize = 1,
};

pub const AutoPolicy = struct {
    enabled: bool = false,
};

pub const Cohort = struct {
    provider: []const u8,
    model: []const u8,
    task_family: []const u8,
    adapter_version: []const u8,
    verifier_version: []const u8,
};

pub const Config = struct {
    schema: []const u8,
    agent_name: []const u8,
    agent_description: []const u8 = "locally learned prompt policy",
    mutation_instruction: []const u8,
    mutator: Program,
    evaluator: Program,
    evaluation_suite: Suite,
    holdout_suite: ?Suite = null,
    limits: Limits = .{},
    gate: Gate = .{},
    auto: AutoPolicy = .{},
    cohort: Cohort,
};

pub const SuiteCase = struct {
    id: []const u8,
    critical: bool = false,
    payload: std.json.Value = .null,
};

pub const SuiteManifest = struct {
    schema: []const u8,
    suite_id: []const u8,
    cases: []const SuiteCase,
};

pub const ActiveRef = struct {
    schema: []const u8,
    config_id: []const u8,
    generation: u64,
    genome_id: []const u8,
    transaction_id: []const u8,
};

pub const Transaction = struct {
    schema: []const u8,
    generation: u64,
    operation: []const u8,
    previous_genome_id: ?[]const u8,
    next_genome_id: []const u8,
    run_id: ?[]const u8,
    previous_transaction_id: ?[]const u8,
    created_unix_ms: i64,
};

pub const LoadedConfig = struct {
    value: Config,
    id: [64]u8,
    bytes: []const u8,
};

pub const LoadedActive = struct {
    ref: ActiveRef,
    transaction: Transaction,
    genome: []const u8,
};

pub const ActiveAgent = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    genome_id: []const u8,
    generation: u64,
};

const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);

/// Persist a directory entry after an atomic link or rename. Io.Dir owns the
/// handle; the temporary Io.File view must never be closed independently.
/// Windows directory handles do not portably support FlushFileBuffers through
/// this API (ACCESS_DENIED is common), so Windows relies on atomic replacement
/// plus synced file contents and has a weaker crash-durability guarantee.
fn syncDirectory(io: Io, dir: Io.Dir) !void {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .wasi and dir.handle == std.posix.AT.FDCWD) {
        var actual = try dir.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
        defer actual.close(io);
        return syncDirectory(io, actual);
    }
    const file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

pub fn validId(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn validName(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

fn validText(value: []const u8, max: usize) bool {
    return value.len > 0 and value.len <= max and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn validEnvName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (!(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return !std.mem.eql(u8, value, "HOME") and
        !std.mem.eql(u8, value, "USERPROFILE") and
        !std.mem.eql(u8, value, "TMPDIR") and
        !std.mem.eql(u8, value, "TMP") and
        !std.mem.eql(u8, value, "TEMP") and
        !std.mem.startsWith(u8, value, "GRAFF_LEARN_");
}

pub fn validateConfig(config: Config) !void {
    if (!std.mem.eql(u8, config.schema, config_schema)) return error.UnsupportedSchema;
    if (!validName(config.agent_name, 64)) return error.InvalidAgentName;
    if (!validText(config.agent_description, 512)) return error.InvalidDescription;
    if (!validText(config.mutation_instruction, 4096)) return error.InvalidMutationInstruction;
    try validateProgram(config.mutator);
    try validateProgram(config.evaluator);
    try validateSuitePin(config.evaluation_suite);
    if (config.holdout_suite) |suite| try validateSuitePin(suite);

    if (config.limits.genome_bytes == 0 or config.limits.genome_bytes > 8 << 20) return error.InvalidLimit;
    if (config.limits.request_bytes < 1024 or config.limits.request_bytes > max_record_bytes) return error.InvalidLimit;
    if (config.limits.response_bytes < 1024 or config.limits.response_bytes > max_record_bytes) return error.InvalidLimit;
    if (config.limits.stdout_bytes > 1 << 20 or config.limits.stderr_bytes > 1 << 20) return error.InvalidLimit;
    if (config.limits.mutator_timeout_ms == 0 or config.limits.mutator_timeout_ms > 3_600_000) return error.InvalidLimit;
    if (config.limits.evaluator_timeout_ms == 0 or config.limits.evaluator_timeout_ms > 3_600_000) return error.InvalidLimit;

    if (config.gate.alpha_ppm == 0 or config.gate.alpha_ppm > 500_000) return error.InvalidGate;
    if (config.gate.minimum_delta_ppm > 1_000_000) return error.InvalidGate;
    if (config.gate.minimum_pairs == 0 or config.gate.minimum_pairs > max_pairs) return error.InvalidGate;
    if (config.gate.default_candidates == 0 or config.gate.default_candidates > 16) return error.InvalidGate;
    if (config.gate.default_repetitions == 0 or config.gate.default_repetitions > 100) return error.InvalidGate;
    if (config.auto.enabled and config.holdout_suite == null) return error.AutoRequiresHoldout;

    inline for (.{ config.cohort.provider, config.cohort.model, config.cohort.task_family, config.cohort.adapter_version, config.cohort.verifier_version }) |field| {
        if (!validText(field, 256)) return error.InvalidCohort;
    }
}

fn validateProgram(program: Program) !void {
    if (!std.fs.path.isAbsolute(program.program) or !validText(program.program, std.fs.max_path_bytes)) return error.InvalidProgramPath;
    if (!validId(program.sha256)) return error.InvalidDigest;
    if (program.args.len > 64 or program.inputs.len > 64 or program.pass_env.len > 32) return error.InvalidProgramConfig;
    for (program.args) |arg| if (arg.len > 4096 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidProgramConfig;
    for (program.inputs, 0..) |input, i| {
        if (!std.fs.path.isAbsolute(input.path) or !validText(input.path, std.fs.max_path_bytes) or !validId(input.sha256)) return error.InvalidProgramConfig;
        for (program.inputs[0..i]) |prior| if (std.mem.eql(u8, prior.path, input.path)) return error.DuplicateProgramInput;
    }
    for (program.pass_env, 0..) |name, i| {
        if (!validEnvName(name)) return error.InvalidEnvironmentName;
        for (program.pass_env[0..i]) |prior| if (std.mem.eql(u8, prior, name)) return error.DuplicateEnvironmentName;
    }
}

fn validateSuitePin(suite: Suite) !void {
    if (!std.fs.path.isAbsolute(suite.path) or !validText(suite.path, std.fs.max_path_bytes)) return error.InvalidSuitePath;
    if (!validId(suite.sha256)) return error.InvalidDigest;
}

pub fn validateSuite(manifest: SuiteManifest) !void {
    if (!std.mem.eql(u8, manifest.schema, suite_schema)) return error.UnsupportedSuiteSchema;
    if (!validName(manifest.suite_id, 128)) return error.InvalidSuiteId;
    if (manifest.cases.len == 0 or manifest.cases.len > max_pairs) return error.InvalidSuiteCases;
    for (manifest.cases, 0..) |case, i| {
        if (!validName(case.id, 128)) return error.InvalidCaseId;
        for (manifest.cases[0..i]) |prior| if (std.mem.eql(u8, prior.id, case.id)) return error.DuplicateCaseId;
    }
}

pub fn rawSha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn domainId(domain: []const u8, bytes: []const u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(&.{0});
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, len[0..], @intCast(bytes.len), .big);
    hash.update(&len);
    hash.update(bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn jsonBytes(gpa: Allocator, value: anytype) ![]u8 {
    var allocating: Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    var stringify: std.json.Stringify = .{ .writer = &allocating.writer };
    try stringify.write(value);
    try allocating.writer.writeByte('\n');
    return gpa.dupe(u8, allocating.writer.buffered());
}

pub fn randomId(io: Io) [64]u8 {
    var raw: [32]u8 = undefined;
    io.randomSecure(&raw) catch io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

pub fn readFileNoFollow(io: Io, dir: Io.Dir, path: []const u8, gpa: Allocator, max: usize) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false })
    else
        try dir.openFile(io, path, .{ .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > max) return error.FileTooBig;
    const size: usize = @intCast(before.size);
    const bytes = try gpa.alloc(u8, size);
    errdefer gpa.free(bytes);
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != size) return error.UnexpectedEndOfFile;
    const after = try file.stat(io);
    if (after.kind != .file or after.size != before.size) return error.FileChanged;
    return bytes;
}

pub fn readPinnedFileAlloc(io: Io, gpa: Allocator, pin: PinnedFile, max: u64) ![]u8 {
    if (!std.fs.path.isAbsolute(pin.path)) return error.PathNotAbsolute;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try Io.Dir.realPathFileAbsolute(io, pin.path, &real_buf);
    if (!std.mem.eql(u8, pin.path, real_buf[0..real_len])) return error.NonCanonicalPath;

    const file = try Io.Dir.openFileAbsolute(io, pin.path, .{ .follow_symlinks = false });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > max or before.size > std.math.maxInt(usize)) return error.FileTooBig;
    if (builtin.os.tag != .windows and (before.permissions.toMode() & 0o022) != 0) return error.InsecurePermissions;

    const bytes = try gpa.alloc(u8, @intCast(before.size));
    errdefer gpa.free(bytes);
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.UnexpectedEndOfFile;
    const after = try file.stat(io);
    if (after.kind != .file or after.size != before.size) return error.FileChanged;
    const actual = rawSha256(bytes);
    if (!std.mem.eql(u8, &actual, pin.sha256)) return error.PinMismatch;
    return bytes;
}

pub fn hashFileNoFollow(io: Io, path: []const u8) ![64]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.PathNotAbsolute;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try Io.Dir.realPathFileAbsolute(io, path, &real_buf);
    if (!std.mem.eql(u8, path, real_buf[0..real_len])) return error.NonCanonicalPath;

    const file = try Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > max_program_bytes) return error.FileTooBig;
    if (builtin.os.tag != .windows and (before.permissions.toMode() & 0o022) != 0) return error.InsecurePermissions;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 << 10]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        const want: usize = @intCast(@min(@as(u64, buffer.len), before.size - offset));
        const got = try file.readPositionalAll(io, buffer[0..want], offset);
        if (got != want) return error.UnexpectedEndOfFile;
        hash.update(buffer[0..got]);
        offset += got;
    }
    const after = try file.stat(io);
    if (after.kind != .file or after.size != before.size) return error.FileChanged;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn verifyPinnedFile(io: Io, pin: PinnedFile) !void {
    const actual = try hashFileNoFollow(io, pin.path);
    if (!std.mem.eql(u8, &actual, pin.sha256)) return error.PinMismatch;
}

pub fn verifyProgram(io: Io, program: Program) !void {
    try verifyPinnedFile(io, .{ .path = program.program, .sha256 = program.sha256 });
    for (program.inputs) |input| try verifyPinnedFile(io, input);
}

pub fn loadSuite(io: Io, arena: Allocator, suite: Suite) !struct { manifest: SuiteManifest, bytes: []const u8 } {
    const bytes = try readPinnedFileAlloc(io, arena, .{ .path = suite.path, .sha256 = suite.sha256 }, max_suite_bytes);
    const manifest = try std.json.parseFromSliceLeaky(SuiteManifest, arena, bytes, .{});
    try validateSuite(manifest);
    return .{ .manifest = manifest, .bytes = bytes };
}

fn openPrivateDir(io: Io, parent: Io.Dir, name: []const u8) !Io.Dir {
    const dir = try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
    if (builtin.os.tag != .windows) {
        const stat = try dir.stat(io);
        if ((stat.permissions.toMode() & 0o077) != 0) return error.InsecurePermissions;
    }
    return dir;
}

fn createPrivateDir(io: Io, parent: Io.Dir, name: []const u8) !Io.Dir {
    try parent.createDir(io, name, dir_permissions);
    var dir = try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    if (builtin.os.tag != .windows) try dir.setPermissions(io, dir_permissions);
    try syncDirectory(io, dir);
    try syncDirectory(io, parent);
    return dir;
}

pub const Store = struct {
    io: Io,
    root: Io.Dir,
    configs: Io.Dir,
    genomes: Io.Dir,
    evidence: Io.Dir,
    runs: Io.Dir,
    transactions: Io.Dir,
    refs: Io.Dir,
    locks: Io.Dir,
    tmp: Io.Dir,

    pub fn initAt(io: Io, base: Io.Dir) !Store {
        base.createDir(io, ".graff", dir_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const graff = try base.openDir(io, ".graff", .{ .iterate = true, .follow_symlinks = false });
        defer graff.close(io);
        try syncDirectory(io, base);
        graff.createDir(io, "learn", dir_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AlreadyInitialized,
            else => return err,
        };
        var root = try graff.openDir(io, "learn", .{ .iterate = true, .follow_symlinks = false });
        errdefer root.close(io);
        if (builtin.os.tag != .windows) try root.setPermissions(io, dir_permissions);
        try syncDirectory(io, root);
        try syncDirectory(io, graff);

        var configs = try createPrivateDir(io, root, "configs");
        errdefer configs.close(io);
        var genomes = try createPrivateDir(io, root, "genomes");
        errdefer genomes.close(io);
        var evidence = try createPrivateDir(io, root, "evidence");
        errdefer evidence.close(io);
        var runs = try createPrivateDir(io, root, "runs");
        errdefer runs.close(io);
        var transactions = try createPrivateDir(io, root, "transactions");
        errdefer transactions.close(io);
        var refs = try createPrivateDir(io, root, "refs");
        errdefer refs.close(io);
        var locks = try createPrivateDir(io, root, "locks");
        errdefer locks.close(io);
        var tmp = try createPrivateDir(io, root, "tmp");
        errdefer tmp.close(io);

        var store: Store = .{ .io = io, .root = root, .configs = configs, .genomes = genomes, .evidence = evidence, .runs = runs, .transactions = transactions, .refs = refs, .locks = locks, .tmp = tmp };
        try store.writeImmutable(store.root, "VERSION", version_bytes, std.heap.page_allocator);
        const lock = try store.locks.createFile(io, "engine.lock", .{ .exclusive = true, .permissions = file_permissions });
        defer lock.close(io);
        try lock.sync(io);
        try syncDirectory(io, store.locks);
        return store;
    }

    pub fn openAt(io: Io, base: Io.Dir) !Store {
        const graff = try base.openDir(io, ".graff", .{ .iterate = true, .follow_symlinks = false });
        defer graff.close(io);
        var root = try openPrivateDir(io, graff, "learn");
        errdefer root.close(io);
        var configs = try openPrivateDir(io, root, "configs");
        errdefer configs.close(io);
        var genomes = try openPrivateDir(io, root, "genomes");
        errdefer genomes.close(io);
        var evidence = try openPrivateDir(io, root, "evidence");
        errdefer evidence.close(io);
        var runs = try openPrivateDir(io, root, "runs");
        errdefer runs.close(io);
        var transactions = try openPrivateDir(io, root, "transactions");
        errdefer transactions.close(io);
        var refs = try openPrivateDir(io, root, "refs");
        errdefer refs.close(io);
        var locks = try openPrivateDir(io, root, "locks");
        errdefer locks.close(io);
        var tmp = try openPrivateDir(io, root, "tmp");
        errdefer tmp.close(io);
        const version = try readFileNoFollow(io, root, "VERSION", std.heap.page_allocator, 16);
        defer std.heap.page_allocator.free(version);
        if (!std.mem.eql(u8, version, version_bytes)) return error.UnsupportedStoreVersion;
        return .{ .io = io, .root = root, .configs = configs, .genomes = genomes, .evidence = evidence, .runs = runs, .transactions = transactions, .refs = refs, .locks = locks, .tmp = tmp };
    }

    pub fn deinit(self: *Store) void {
        self.tmp.close(self.io);
        self.locks.close(self.io);
        self.refs.close(self.io);
        self.transactions.close(self.io);
        self.runs.close(self.io);
        self.evidence.close(self.io);
        self.genomes.close(self.io);
        self.configs.close(self.io);
        self.root.close(self.io);
        self.* = undefined;
    }

    pub const LockGuard = struct {
        io: Io,
        file: Io.File,

        pub fn deinit(self: *LockGuard) void {
            self.file.unlock(self.io);
            self.file.close(self.io);
            self.* = undefined;
        }
    };

    pub fn acquireLock(self: *Store, timeout_ms: u64) !LockGuard {
        const file = try self.locks.openFile(self.io, "engine.lock", .{ .mode = .read_write, .follow_symlinks = false, .resolve_beneath = true });
        errdefer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.InvalidLockFile;
        const start: Io.Timestamp = .now(self.io, .awake);
        while (!try file.tryLock(self.io, .exclusive)) {
            if (start.untilNow(self.io, .awake).toMilliseconds() >= timeout_ms) return error.EngineBusy;
            self.io.sleep(.fromMilliseconds(25), .awake) catch return error.EngineBusy;
        }
        return .{ .io = self.io, .file = file };
    }

    fn writeImmutable(self: *Store, dir: Io.Dir, name: []const u8, bytes: []const u8, gpa: Allocator) !void {
        var atomic = try dir.createFileAtomic(self.io, name, .{ .permissions = file_permissions, .replace = false });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        atomic.link(self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const existing = try readFileNoFollow(self.io, dir, name, gpa, bytes.len + 1);
                defer gpa.free(existing);
                if (!std.mem.eql(u8, existing, bytes)) return error.ImmutableObjectConflict;
            },
            else => return err,
        };
        try syncDirectory(self.io, dir);
    }

    fn writeAtomicReplace(self: *Store, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
        var atomic = try dir.createFileAtomic(self.io, name, .{ .permissions = file_permissions, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        try syncDirectory(self.io, dir);
    }

    fn objectName(id: []const u8, extension: []const u8, buffer: []u8) ![]const u8 {
        if (!validId(id)) return error.InvalidId;
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ id, extension });
    }

    fn writeAddressed(self: *Store, gpa: Allocator, dir: Io.Dir, domain: []const u8, extension: []const u8, bytes: []const u8) ![64]u8 {
        const id = domainId(domain, bytes);
        var name_buf: [80]u8 = undefined;
        const name = try objectName(&id, extension, &name_buf);
        try self.writeImmutable(dir, name, bytes, gpa);
        return id;
    }

    fn readAddressed(self: *Store, arena: Allocator, dir: Io.Dir, domain: []const u8, extension: []const u8, id: []const u8, max: usize) ![]const u8 {
        var name_buf: [80]u8 = undefined;
        const name = try objectName(id, extension, &name_buf);
        const bytes = try readFileNoFollow(self.io, dir, name, arena, max);
        if (!std.mem.eql(u8, &domainId(domain, bytes), id)) return error.ObjectHashMismatch;
        return bytes;
    }

    pub fn writeGenome(self: *Store, gpa: Allocator, bytes: []const u8) ![64]u8 {
        if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidGenome;
        return self.writeAddressed(gpa, self.genomes, "codegraff-learn/genome/v1", ".md", bytes);
    }

    pub fn readGenome(self: *Store, arena: Allocator, id: []const u8, max: usize) ![]const u8 {
        return self.readAddressed(arena, self.genomes, "codegraff-learn/genome/v1", ".md", id, max);
    }

    pub fn writeEvidence(self: *Store, gpa: Allocator, bytes: []const u8) ![64]u8 {
        return self.writeAddressed(gpa, self.evidence, "codegraff-learn/evidence/v1", ".json", bytes);
    }

    pub fn readEvidence(self: *Store, arena: Allocator, id: []const u8, max: usize) ![]const u8 {
        return self.readAddressed(arena, self.evidence, "codegraff-learn/evidence/v1", ".json", id, max);
    }

    pub fn writeRun(self: *Store, gpa: Allocator, bytes: []const u8) ![64]u8 {
        return self.writeAddressed(gpa, self.runs, "codegraff-learn/run/v1", ".json", bytes);
    }

    pub fn readRun(self: *Store, arena: Allocator, id: []const u8) ![]const u8 {
        return self.readAddressed(arena, self.runs, "codegraff-learn/run/v1", ".json", id, max_record_bytes);
    }

    pub fn writeTransaction(self: *Store, gpa: Allocator, bytes: []const u8) ![64]u8 {
        return self.writeAddressed(gpa, self.transactions, "codegraff-learn/transaction/v1", ".json", bytes);
    }

    pub fn readTransaction(self: *Store, arena: Allocator, id: []const u8) ![]const u8 {
        return self.readAddressed(arena, self.transactions, "codegraff-learn/transaction/v1", ".json", id, max_record_bytes);
    }

    pub fn loadConfig(self: *Store, arena: Allocator) !LoadedConfig {
        const bytes = try readFileNoFollow(self.io, self.root, "config.json", arena, max_config_bytes);
        const id = domainId("codegraff-learn/config/v1", bytes);
        const value = try std.json.parseFromSliceLeaky(Config, arena, bytes, .{});
        try validateConfig(value);
        var name_buf: [80]u8 = undefined;
        const object_name = try objectName(&id, ".json", &name_buf);
        const immutable = try readFileNoFollow(self.io, self.configs, object_name, arena, max_config_bytes);
        if (!std.mem.eql(u8, immutable, bytes)) return error.ConfigChanged;
        return .{ .value = value, .id = id, .bytes = bytes };
    }

    pub fn bootstrap(self: *Store, gpa: Allocator, arena: Allocator, config_bytes: []const u8, parent: []const u8, created_unix_ms: i64) ![64]u8 {
        const config = try std.json.parseFromSliceLeaky(Config, arena, config_bytes, .{});
        try validateConfig(config);
        if (parent.len > config.limits.genome_bytes or std.mem.trim(u8, parent, " \t\r\n").len == 0) return error.InvalidGenome;
        const config_id = domainId("codegraff-learn/config/v1", config_bytes);
        var config_name_buf: [80]u8 = undefined;
        const config_name = try objectName(&config_id, ".json", &config_name_buf);
        try self.writeImmutable(self.configs, config_name, config_bytes, gpa);
        try self.writeImmutable(self.root, "config.json", config_bytes, gpa);
        const genome_id = try self.writeGenome(gpa, parent);

        const tx: Transaction = .{
            .schema = transaction_schema,
            .generation = 0,
            .operation = "init",
            .previous_genome_id = null,
            .next_genome_id = &genome_id,
            .run_id = null,
            .previous_transaction_id = null,
            .created_unix_ms = created_unix_ms,
        };
        const tx_bytes = try jsonBytes(gpa, tx);
        defer gpa.free(tx_bytes);
        const tx_id = try self.writeTransaction(gpa, tx_bytes);
        const active: ActiveRef = .{
            .schema = active_schema,
            .config_id = &config_id,
            .generation = 0,
            .genome_id = &genome_id,
            .transaction_id = &tx_id,
        };
        const active_bytes = try jsonBytes(gpa, active);
        defer gpa.free(active_bytes);
        try self.writeImmutable(self.refs, "active.json", active_bytes, gpa);
        return genome_id;
    }

    pub fn validateTransactionChain(self: *Store, arena: Allocator, transaction_id: []const u8, transaction: Transaction) !void {
        if (!validId(transaction_id)) return error.InvalidId;
        var current = transaction;
        while (true) {
            try validateTransaction(current);
            if (current.generation == 0) break;
            const previous_id = current.previous_transaction_id orelse return error.BrokenTransactionChain;
            const previous_bytes = try self.readTransaction(arena, previous_id);
            const previous = try std.json.parseFromSliceLeaky(Transaction, arena, previous_bytes, .{});
            try validateTransaction(previous);
            const expected_generation = std.math.add(u64, previous.generation, 1) catch return error.BrokenTransactionChain;
            if (expected_generation != current.generation or
                !std.mem.eql(u8, previous.next_genome_id, current.previous_genome_id.?)) return error.BrokenTransactionChain;
            current = previous;
        }
    }

    fn ensureExpectedActive(self: *Store, gpa: Allocator, expected: ActiveRef, config_id: []const u8) !void {
        const bytes = try readFileNoFollow(self.io, self.refs, "active.json", gpa, max_record_bytes);
        defer gpa.free(bytes);
        var parsed = try std.json.parseFromSlice(ActiveRef, gpa, bytes, .{});
        defer parsed.deinit();
        const current = parsed.value;
        if (!std.mem.eql(u8, current.schema, active_schema) or
            !std.mem.eql(u8, current.config_id, config_id) or
            current.generation != expected.generation or
            !std.mem.eql(u8, current.genome_id, expected.genome_id) or
            !std.mem.eql(u8, current.transaction_id, expected.transaction_id)) return error.ActiveRefChanged;
    }

    pub fn loadActive(self: *Store, arena: Allocator, config: LoadedConfig) !LoadedActive {
        const active_bytes = try readFileNoFollow(self.io, self.refs, "active.json", arena, max_record_bytes);
        const active = try std.json.parseFromSliceLeaky(ActiveRef, arena, active_bytes, .{});
        if (!std.mem.eql(u8, active.schema, active_schema) or !validId(active.config_id) or !validId(active.genome_id) or !validId(active.transaction_id)) return error.InvalidActiveRef;
        if (!std.mem.eql(u8, active.config_id, &config.id)) return error.ConfigChanged;
        const tx_bytes = try self.readTransaction(arena, active.transaction_id);
        const tx = try std.json.parseFromSliceLeaky(Transaction, arena, tx_bytes, .{});
        try validateTransaction(tx);
        if (tx.generation != active.generation or !std.mem.eql(u8, tx.next_genome_id, active.genome_id)) return error.InvalidActiveRef;
        try self.validateTransactionChain(arena, active.transaction_id, tx);
        const genome = try self.readGenome(arena, active.genome_id, config.value.limits.genome_bytes);
        return .{ .ref = active, .transaction = tx, .genome = genome };
    }

    pub fn activate(self: *Store, gpa: Allocator, expected: ActiveRef, config_id: []const u8, next_genome_id: []const u8, run_id: ?[]const u8, operation: []const u8, max_genome_bytes: usize, created_unix_ms: i64) !void {
        if (!std.mem.eql(u8, operation, "promote") and !std.mem.eql(u8, operation, "rollback")) return error.InvalidOperation;
        if (!validId(config_id) or !validId(next_genome_id)) return error.InvalidId;
        if (run_id) |id| if (!validId(id)) return error.InvalidId;
        if (max_genome_bytes == 0 or max_genome_bytes > max_record_bytes) return error.InvalidLimit;
        try self.ensureExpectedActive(gpa, expected, config_id);
        const verified_genome = try self.readGenome(gpa, next_genome_id, max_genome_bytes);
        defer gpa.free(verified_genome);
        const generation = std.math.add(u64, expected.generation, 1) catch return error.GenerationOverflow;
        const tx: Transaction = .{
            .schema = transaction_schema,
            .generation = generation,
            .operation = operation,
            .previous_genome_id = expected.genome_id,
            .next_genome_id = next_genome_id,
            .run_id = run_id,
            .previous_transaction_id = expected.transaction_id,
            .created_unix_ms = created_unix_ms,
        };
        const tx_bytes = try jsonBytes(gpa, tx);
        defer gpa.free(tx_bytes);
        const tx_id = try self.writeTransaction(gpa, tx_bytes);
        const active: ActiveRef = .{
            .schema = active_schema,
            .config_id = config_id,
            .generation = generation,
            .genome_id = next_genome_id,
            .transaction_id = &tx_id,
        };
        const active_bytes = try jsonBytes(gpa, active);
        defer gpa.free(active_bytes);
        try self.writeAtomicReplace(self.refs, "active.json", active_bytes);
    }
};

pub fn validateTransaction(tx: Transaction) !void {
    if (!std.mem.eql(u8, tx.schema, transaction_schema)) return error.UnsupportedSchema;
    if (!std.mem.eql(u8, tx.operation, "init") and !std.mem.eql(u8, tx.operation, "promote") and !std.mem.eql(u8, tx.operation, "rollback")) return error.InvalidOperation;
    if (!validId(tx.next_genome_id)) return error.InvalidId;
    if (tx.previous_genome_id) |id| if (!validId(id)) return error.InvalidId;
    if (tx.run_id) |id| if (!validId(id)) return error.InvalidId;
    if (tx.previous_transaction_id) |id| if (!validId(id)) return error.InvalidId;
    if (std.mem.eql(u8, tx.operation, "init")) {
        if (tx.generation != 0 or tx.previous_genome_id != null or tx.previous_transaction_id != null or tx.run_id != null) return error.InvalidTransaction;
    } else if (tx.generation == 0 or tx.previous_genome_id == null or tx.previous_transaction_id == null) return error.InvalidTransaction;
    if (std.mem.eql(u8, tx.operation, "promote") and tx.run_id == null) return error.InvalidTransaction;
    if (std.mem.eql(u8, tx.operation, "rollback") and tx.run_id != null) return error.InvalidTransaction;
}

/// Best-effort, fail-closed bridge into the ordinary agent registry. Corrupt or
/// incomplete learning state never becomes an executable prompt policy.
pub fn loadActiveAgent(io: Io, arena: Allocator) ?ActiveAgent {
    var store = Store.openAt(io, Io.Dir.cwd()) catch return null;
    defer store.deinit();
    const config = store.loadConfig(arena) catch return null;
    const active = store.loadActive(arena, config) catch return null;
    return .{
        .name = config.value.agent_name,
        .description = config.value.agent_description,
        .prompt = active.genome,
        .genome_id = active.ref.genome_id,
        .generation = active.ref.generation,
    };
}

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
