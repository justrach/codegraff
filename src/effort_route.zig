//! Per-turn effort routing (k3 benchmark, 2026-08): a lookup/Q&A-shaped
//! SUBAGENT turn runs at low effort when that child inherited the stock
//! `.medium` default (no effort pin). Root never routes: `reasoning_effort`
//! / `reasoning.effort` sits in the cached prefix, and flipping it mid-
//! conversation misses the prompt cache and breaks the WS chain fingerprint
//! (codex_chain.propsFp). Children already have their own conv id.
//!
//! Edit-shaped prompts keep the default: low effort there INFLATES tool-
//! call count (permgate went 11→16 calls and +85% wall). An explicit
//! /effort or a worker `effort:` pin always wins.

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

/// Root stays sticky for cache. Only an unpinned child (default medium) may
/// drop a lookup-shaped task to low.
pub fn shouldRouteLookupLow(is_sub: bool, default_medium: bool, prompt: []const u8) bool {
    return is_sub and default_medium and routesToLowEffort(prompt);
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
    try std.testing.expect(!shouldRouteLookupLow(false, true, q)); // root: keep the cached prefix
    try std.testing.expect(shouldRouteLookupLow(true, true, q)); // unpinned child
    try std.testing.expect(!shouldRouteLookupLow(true, false, q)); // explicit effort pin
    try std.testing.expect(!shouldRouteLookupLow(true, true, "fix the failing test"));
}
