//! Where the harness's own policy lives: approvals, lifecycle hooks, per-skill
//! opt-outs, the animation/theme preference, the fallback allow-list. One
//! workspace file, read and rewritten by half a dozen modules.
//!
//! A leaf with no imports, because the PATH is not a policy concern (#429):
//! before this, `Approvals.settings_path` was the only name for it, so a module
//! that merely wanted to read the file — hooks.zig, which parses the "hooks"
//! object out of it — had to import approvals.zig, a terminal-cluster module
//! that prompts the user. approvals.zig re-exports this as
//! `Approvals.settings_path`, so every existing call site is unchanged.
pub const path = ".harness/settings.json";
