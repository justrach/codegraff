test {
    _ = @import("readline_history.zig");
    _ = @import("codedbpro_paths.zig");
    _ = @import("agent_request_body_responses.zig");
    _ = @import("agent_server_compact_tests.zig");
    _ = @import("provider_codegraff_tests.zig");
}

test "oneshot -p still uses the live stall-watched transport" {
    try @import("agent_tests.zig").oneshotUsesLiveTransport(@import("agent.zig").Agent);
}
