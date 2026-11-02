//! Which shell commands the codedb guard (#626, `tools.codedbGuard`) lets
//! through even though they name an indexed source file (ADR 0234).
//!
//! The guard moves source SEARCHES, and reads of files too big to take whole,
//! onto codedb. Two shapes are neither, and blocking them only cost the model
//! a round trip: an in-place edit (`sed -i`) writes the file and reads nothing
//! back, a write-only `cat > file <<'EOF'` (or `>>`) reads no file at all, and
//! a whole-file read of a small file returns no more than a `read_file` would.
//! Output redirection targets are destinations, never counted as reads (#1709).

const std = @import("std");
const Io = std.Io;

/// A whole-file read of files up to this size passes: the size a tool result
/// keeps inline before it becomes a handle.
pub const small_read_bytes: u64 = @import("tool_handle.zig").default_threshold_bytes;

/// `sed` with an in-place flag (`-i`, `-i ''`, `-i.bak`, `-Ei`, `--in-place`)
/// in its first command segment.
pub fn inPlaceEdit(tool: []const u8, cmd: []const u8) bool {
    if (!std.mem.eql(u8, tool, "sed")) return false;
    const segment = cmd[0 .. std.mem.indexOfAny(u8, cmd, ";|&\n") orelse cmd.len];
    var it = std.mem.tokenizeAny(u8, segment, " \t");
    _ = it.next(); // sed itself
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "--in-place")) return true;
        if (tok.len < 2 or tok[0] != '-' or tok[1] == '-') continue;
        // A short-flag cluster: letters only up to an optional backup suffix.
        if (std.mem.indexOfScalar(u8, tok[1..], 'i')) |i| {
            if (std.mem.indexOfNone(u8, tok[1 .. 1 + i], "Ealnrsuz") == null) return true;
        }
    }
    return false;
}

/// Every exemption, for the guard in `tools.zig::codedbGuard`. Paths resolve
/// in the agent's own worktree when it has one, else the process cwd.
pub fn exempt(io: Io, agent_cwd: ?[]const u8, tool: []const u8, cmd: []const u8) bool {
    return inPlaceEdit(tool, cmd) or writeOnly(tool, cmd) or smallReadIn(io, agent_cwd, tool, cmd);
}

/// `exempt` against an open directory (tests).
pub fn exemptAt(io: Io, cwd: Io.Dir, tool: []const u8, cmd: []const u8) bool {
    return inPlaceEdit(tool, cmd) or writeOnly(tool, cmd) or smallRead(io, cwd, tool, cmd);
}

/// `cat` whose first command segment names no input file and sends stdout to
/// a file: `cat > f <<'EOF'`, `cat >> f <<EOF`, `cat > f`. Its input is a
/// heredoc, a here-string or stdin, so no source is read however large the
/// destination is. Any file operand (`cat big.zig > out`), `<` input
/// redirection or command substitution makes it a read the guard still
/// checks.
pub fn writeOnly(tool: []const u8, cmd: []const u8) bool {
    if (!std.mem.eql(u8, tool, "cat")) return false;
    var i: usize = std.mem.indexOfAny(u8, cmd, " \t") orelse return false; // past `cat`
    var target: enum { none, file, word } = .none; // what the next word is
    var stdout_to_file = false;
    while (true) {
        while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
        if (i >= cmd.len) break;
        const c = cmd[i];
        if (c == ';' or c == '|' or c == '\n') break; // end of the first segment
        if (c == '&' and !(i + 1 < cmd.len and cmd[i + 1] == '>')) break; // `&&`, `&`
        // An optional fd (`2>`, `1>>`) or `&` (stdout and stderr) before the operator.
        var fd_end = i;
        while (fd_end < cmd.len and std.ascii.isDigit(cmd[fd_end])) fd_end += 1;
        if (fd_end == i and c == '&') fd_end += 1;
        if (fd_end < cmd.len and (cmd[fd_end] == '>' or cmd[fd_end] == '<')) {
            if (target != .none) return false; // an operator where a target belongs
            const fd = cmd[i..fd_end];
            i = fd_end;
            if (cmd[i] == '>') {
                i += 1;
                if (i < cmd.len and (cmd[i] == '>' or cmd[i] == '|')) i += 1;
                if (i < cmd.len and cmd[i] == '&') { // `>&2`: a dup, not a file
                    i += 1;
                    while (i < cmd.len and (std.ascii.isDigit(cmd[i]) or cmd[i] == '-')) i += 1;
                    continue;
                }
                if (fd.len == 0 or std.mem.eql(u8, fd, "1") or std.mem.eql(u8, fd, "&")) stdout_to_file = true;
                target = .file;
            } else {
                i += 1;
                if (i < cmd.len and cmd[i] == '<') { // heredoc `<<`/`<<-` or here-string `<<<`
                    i += 1;
                    if (i < cmd.len and (cmd[i] == '<' or cmd[i] == '-')) i += 1;
                    target = .word;
                } else if (i < cmd.len and cmd[i] == '&') { // `<&3`: a dup
                    i += 1;
                    while (i < cmd.len and (std.ascii.isDigit(cmd[i]) or cmd[i] == '-')) i += 1;
                } else return false; // `< file`, `<> file`: reads a file
            }
            continue;
        }
        // A word, with quotes kept whole.
        const start = i;
        while (i < cmd.len and std.mem.indexOfScalar(u8, " \t\n;|&<>", cmd[i]) == null) {
            if (cmd[i] == '\'' or cmd[i] == '"') {
                const close = std.mem.indexOfScalarPos(u8, cmd, i + 1, cmd[i]) orelse return false;
                i = close;
            }
            i += 1;
        }
        const word = cmd[start..i];
        if (std.mem.indexOfScalar(u8, word, '`') != null or std.mem.indexOf(u8, word, "$(") != null) return false;
        if (target != .none) {
            target = .none;
            continue;
        }
        if (word.len > 0 and word[0] == '-') continue; // a flag, or `-` for stdin
        return false; // a file operand: this cat reads
    }
    return target == .none and stdout_to_file;
}

/// An output redirection token: `>`, `>>`, `2>`, `&>>`, `>|` alone (target is
/// the next token) or with its target attached (`>out`, `2>/dev/null`).
fn outputRedirect(tok: []const u8) ?enum { alone, attached } {
    var i: usize = 0;
    while (i < tok.len and std.ascii.isDigit(tok[i])) i += 1;
    if (i == 0 and i < tok.len and tok[i] == '&') i += 1;
    if (i >= tok.len or tok[i] != '>') return null;
    i += 1;
    if (i < tok.len and (tok[i] == '>' or tok[i] == '|')) i += 1;
    return if (i == tok.len) .alone else .attached;
}

fn plainReader(tool: []const u8) bool {
    for ([_][]const u8{ "cat", "head", "tail", "nl", "wc", "bat", "batcat" }) |reader|
        if (std.mem.eql(u8, reader, tool)) return true;
    return false;
}

/// `smallRead` in the directory the command runs in: the agent's own
/// worktree when it has one, else the process cwd.
pub fn smallReadIn(io: Io, agent_cwd: ?[]const u8, tool: []const u8, cmd: []const u8) bool {
    const path = agent_cwd orelse return smallRead(io, Io.Dir.cwd(), tool, cmd);
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);
    return smallRead(io, dir, tool, cmd);
}

/// A plain reader (cat/head/tail/nl/wc/bat) with no pipe (`cat x | grep` is a
/// search) whose every named input file is at most `small_read_bytes`; an
/// output redirection target is written, not read, so its size is not
/// counted. Paths resolve against `cwd`, where the command runs.
pub fn smallRead(io: Io, cwd: Io.Dir, tool: []const u8, cmd: []const u8) bool {
    if (!plainReader(tool)) return false;
    if (std.mem.indexOfScalar(u8, cmd, '|') != null) return false;
    var it = std.mem.tokenizeAny(u8, cmd, " \t\n;&");
    var files: usize = 0;
    while (it.next()) |raw| {
        if (outputRedirect(raw)) |form| {
            if (form == .alone) _ = it.next(); // skip the destination
            continue;
        }
        const tok = std.mem.trim(u8, raw, "'\"`()");
        if (tok.len == 0 or tok[0] == '-') continue;
        const st = cwd.statFile(io, tok, .{}) catch continue; // a command word, a flag value, a missing file
        if (st.kind != .file) continue;
        if (st.size > small_read_bytes) return false;
        files += 1;
    }
    return files > 0;
}

test "inPlaceEdit: in-place sed edits, not reads or scripts" {
    try std.testing.expect(inPlaceEdit("sed", "sed -i '' 's/range(n - 1)/range(n)/' fib.py && python3 test_fib.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed -i 's/a/b/' x.py; python3 x.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed -i.bak -e 's/a/b/' x.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed -Ei 's/a/b/g' x.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed --in-place=.orig 's/a/b/' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -n '1,20p' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -n 's/i/x/p' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -e 's/i/x/' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -n 1p x.py; sed -i '' 's/a/b/' y.py")); // the edit is not the guarded command
    try std.testing.expect(!inPlaceEdit("grep", "grep -i foo x.py"));
}

test "smallRead: whole small files pass; big files, pipes and searches do not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "small.py", .data = "print(1)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.py", .data = "x = 2\n" });
    const big = try std.testing.allocator.alloc(u8, small_read_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try tmp.dir.writeFile(io, .{ .sub_path = "big.py", .data = big });

    try std.testing.expect(smallRead(io, tmp.dir, "cat", "cat small.py; cat other.py"));
    try std.testing.expect(smallRead(io, tmp.dir, "head", "head -n 40 small.py"));
    try std.testing.expect(!smallRead(io, tmp.dir, "cat", "cat small.py big.py"));
    try std.testing.expect(!smallRead(io, tmp.dir, "cat", "cat small.py | grep print"));
    try std.testing.expect(!smallRead(io, tmp.dir, "grep", "grep print small.py"));
    try std.testing.expect(!smallRead(io, tmp.dir, "cat", "cat missing.py"));
}

test "writeOnly: heredoc and redirect-only cat writes are not reads (#1709)" {
    try std.testing.expect(writeOnly("cat", "cat > src/synthetic.rs <<'EOF'\n// synthetic append\nEOF"));
    try std.testing.expect(writeOnly("cat", "cat >> src/synthetic.rs <<'EOF'\n// synthetic append\nEOF"));
    try std.testing.expect(writeOnly("cat", "cat >>src/x.rs <<EOF\nfn main() {}\nEOF"));
    try std.testing.expect(writeOnly("cat", "cat <<-\"EOF\" > out.zig\nconst x = 1;\nEOF"));
    try std.testing.expect(writeOnly("cat", "cat > out.py <<< 'print(1)'"));
    try std.testing.expect(writeOnly("cat", "cat > out.rs"));
    try std.testing.expect(writeOnly("cat", "cat 2>/dev/null >> out.rs <<'EOF'\nx\nEOF\nzig build"));
    // The heredoc body never counts as operands.
    try std.testing.expect(writeOnly("cat", "cat > a.zig <<'EOF'\ncat big.zig b.zig\nEOF"));

    // Mixed read/write and plain reads are still checked.
    try std.testing.expect(!writeOnly("cat", "cat big.zig > out"));
    try std.testing.expect(!writeOnly("cat", "cat a.rs b.rs >> c.rs"));
    try std.testing.expect(!writeOnly("cat", "cat > out.rs < big.rs"));
    try std.testing.expect(!writeOnly("cat", "cat >out.rs<big.rs"));
    try std.testing.expect(!writeOnly("cat", "cat > \"$(grep -l x big.rs)\" <<'EOF'\nx\nEOF"));
    try std.testing.expect(!writeOnly("cat", "cat big.rs"));
    try std.testing.expect(!writeOnly("cat", "cat <<'EOF' | grep x\nx\nEOF")); // no file destination
    try std.testing.expect(!writeOnly("cat", "cat 2> err.log big.rs"));
    try std.testing.expect(!writeOnly("cat", "cat >"));
    try std.testing.expect(!writeOnly("tee", "tee out.rs <<'EOF'\nx\nEOF"));
}

test "exempt: large write destinations pass, large source reads do not (#1709)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const big = try std.testing.allocator.alloc(u8, small_read_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try tmp.dir.writeFile(io, .{ .sub_path = "big.rs", .data = big });
    try tmp.dir.writeFile(io, .{ .sub_path = "dest.rs", .data = big });
    try tmp.dir.writeFile(io, .{ .sub_path = "small.rs", .data = "fn a() {}\n" });

    try std.testing.expect(exemptAt(io, tmp.dir, "cat", "cat >> dest.rs <<'EOF'\n// synthetic append\nEOF"));
    try std.testing.expect(exemptAt(io, tmp.dir, "cat", "cat > dest.rs <<'EOF'\n// synthetic\nEOF"));
    // Reading a small file into a large destination reads only the small file.
    try std.testing.expect(exemptAt(io, tmp.dir, "cat", "cat small.rs >> dest.rs"));
    try std.testing.expect(exemptAt(io, tmp.dir, "cat", "cat small.rs >dest.rs"));
    try std.testing.expect(!exemptAt(io, tmp.dir, "cat", "cat big.rs > out.rs"));
    try std.testing.expect(!exemptAt(io, tmp.dir, "cat", "cat small.rs big.rs >> dest.rs"));
    try std.testing.expect(!exemptAt(io, tmp.dir, "cat", "cat > out.rs < big.rs"));
    try std.testing.expect(!exemptAt(io, tmp.dir, "grep", "grep fn big.rs > out.txt"));
}
