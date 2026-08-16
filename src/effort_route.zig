//! Lookup-shape detector. Used to decide a prompt is Q&A vs mutation.
//! The harness does NOT auto-flip `reasoning_effort` — that field is part
//! of the cached prefix on Codex, OpenAI, xAI, DeepSeek, and the codegraff
//! gateway. Changing it mid-conversation misses the cache and drops the
//! WS chain (codex_chain.propsFp). An explicit /effort or a worker
//! `effort:` pin is the only way effort moves.

const std = @import("std");

/// Case-insensitive substring check, no allocation.
fn containsI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const lookup_cues = [_][]const u8{
    "what ",        "what's",    "how do",  "how does", "how is",        "where ",
    "which ",       "why ",      "explain", "list ",    "tell me",       "describe",
    "show me",      "summarize", "who ",    "?",        "do not modify", "do not change",
    "don't change", "read-only",
};

const mutation_cues = [_][]const u8{
    "fix",        "implement",   " add ",   "update ", "refactor", "write ",
    "create",     "delete",      "remove ", "rewrite", "build ",   "run ",
    "commit",     "install",     "rename",  "patch",   "bump",     "edit ",
    "change the", "change this",
    // NOTE: bare "modify "/"change " are deliberately absent — read-only tasks
    // habitually end with "do not modify any files", and poisoning on that
    // phrase would exclude exactly the prompts this router exists for.
};

/// True when a prompt is shaped like a read-only lookup: it carries a question
/// or explanation cue and NO mutation cue. Conservative by construction — a
/// miss just means the turn runs at the session default.
pub fn routesToLowEffort(prompt: []const u8) bool {
    if (prompt.len < 12) return false; // "fix it" is short; questions carry words
    for (mutation_cues) |cue| if (containsI(prompt, cue)) return false;
    for (lookup_cues) |cue| if (containsI(prompt, cue)) return true;
    return false;
}

/// Never auto-route. Kept so a caller cannot quietly reintroduce a prefix
/// flip: the gate is closed for root and children alike.
pub fn shouldRouteLookupLow(_: bool, _: bool, _: []const u8) bool {
    return false;
}

test "lookup prompts route low, mutation prompts and bare commands do not" {
    // The three benchmark tasks are the pinned shape: two route low, and the
    // one that REGRESSED at low effort (permgate) must not route.
    try std.testing.expect(routesToLowEffort("In src/main.zig of this repository, what does the function runEval do, and which other functions or methods does it call? Answer in 4-5 sentences. Do not modify any files."));
    try std.testing.expect(routesToLowEffort("In this repository, list the AI model providers graff supports, and for each give its wire-format/auth style and the environment variable for its API key. Be concise. Do not modify any files."));
    try std.testing.expect(!routesToLowEffort("In this repository, how does the permission gate decide whether a bash command needs approval, and what rule lets read-only commands run without prompting? Name the key function(s) by name. Answer in 4-5 sentences. Do not modify any files.")); // "run without" — the task that inflated at low
    try std.testing.expect(!routesToLowEffort("fix the failing test in agent.zig"));
    try std.testing.expect(!routesToLowEffort("implement the feature and update the docs"));
    try std.testing.expect(!routesToLowEffort("hi"));
    try std.testing.expect(routesToLowEffort("Explain how the permission gate works here?"));
    const q = "Explain how the permission gate works here?";
    try std.testing.expect(!shouldRouteLookupLow(false, true, q));
    try std.testing.expect(!shouldRouteLookupLow(true, true, q));
}
