//! Needle tables for `shapes.classOf` / `isAuditClass`.
//! Single source: the spec export parses this file.

pub const audit = [_][]const u8{
    "thorough",       "exhaustive", "comprehensive",       "audit",
    "every file",     "all files",  "across the codebase", "across the repo",
    "systematically", "full sweep", "end-to-end review",
};

pub const bugfix = [_][]const u8{
    "fix ",         "bug",           "is broken", "are broken",
    "broken test",  "broken build",  "failing",   "fails",
    "regression",   "crash",         "repair",    "make the tests pass",
    "doesn't work", "does not work",
};

pub const refactor = [_][]const u8{
    "refactor", "rename",   "extract ", "restructure", "deduplicate",
    "dedupe",   "move the", "port the", "migrate",
};

pub const review = [_][]const u8{
    "review", "audit", "critique", "find bugs", "security review", "code smell",
};

pub const research = [_][]const u8{
    "how does",  "how do ",   "why does",  "explain",         "investigate",    "research",
    "summarize", "summarise", "summary",   "understand",      "what is the",    "which ",
    "map the",   "trace how", "answering", "these questions", "four questions", "cite the",
};

pub const feature = [_][]const u8{
    "add ",        "implement", "build ", "create ", "write ", "support for",
    "new feature", "feature",
};
