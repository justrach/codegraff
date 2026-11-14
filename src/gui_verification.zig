//! GUI verification policy for root and child agents, independent of model,
//! client, and tool capability gates. The open shim is only defense in depth.
const std = @import("std");

pub const guidance =
    \\
    \\
    \\GUI verification must preserve the user's desktop. Default to headless,
    \\hidden non-activating fixtures or an isolated graphical session, with
    \\synthetic data and a disposable profile. A background shell job, open -g,
    \\or process-targeted input alone does not prevent an app activating itself
    \\or leaving visible windows. Inspect launch, window creation, reopen and
    \\later focus paths before running GUI helpers, including generated native
    \\examples. Do not copy activation calls (such as cx.activate(true)), show,
    \\focus, global mouse/keyboard injection or live-user state into a default
    \\verification helper. Reuse a source-compatible fixture/capture helper;
    \\finish typed root/entity mutations before rendering or dispatching callbacks
    \\that can re-enter that root. Arrange cleanup of owned windows/processes on
    \\success, failure and interruption; do not close the user's own apps.
    \\A request to test, capture a screenshot or verify a native UI is not consent
    \\to take desktop focus. If foreground semantics are essential, use an isolated
    \\graphical session or leave that coverage explicitly unverified. A bounded
    \\foreground diagnostic on the user's desktop requires explicit user opt-in;
    \\GRAFF_GUI_FOREGROUND=1 expresses an authorized launch, not permission the
    \\agent may grant itself. Respect a user app switch or pointer movement: stop
    \\foreground interaction rather than reactivating or reclaiming focus.
    \\Explicitly requested computer-use remains available within its authorized
    \\scope and tool permissions. A denied/unavailable computer-use tool is not
    \\permission to fall back to activation or global input through shell helpers;
    \\report the actual denial without inventing permission controls.
    \\Keep functional assertions separate from desktop-isolation evidence: only
    \\an OS-observed check in an isolated graphical session establishes preserved
    \\focus, cursor and cleanup; a mock launch test or screenshot does not.
    \\Report skipped native checks and abnormal helper exits as failed/unverified
    \\coverage, not a production-app crash or a pass; a successful retry does not
    \\erase an earlier crash or desktop side effect.
;

test "#832 GUI safety survives root variants, subagents and absent local tools" {
    const prompts = @import("prompts.zig");
    for ([_][]const u8{
        prompts.main_system_prompt,
        prompts.main_system_prompt_strict,
        prompts.main_system_prompt_ultra_strict,
        prompts.sub_system_prompt,
    }) |prompt| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, prompt, guidance));
    // MCP-only agents can still drive a desktop: removing shell tools must not
    // remove this boundary, unlike shell-specific instructions.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mcp_only = try prompts.composeBase(arena.allocator(), .{
        .local_tools = false,
        .subagents = false,
        .todos = false,
        .constraints = false,
    });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, mcp_only, guidance));
}
