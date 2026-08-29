//! Small per-request operational-observability helpers kept out of Agent's
//! already-near-limit definition and the provider-specific stream parsers.

pub fn firstToken(self: anytype) void {
    if (self.first_token_traced) return;
    const started = self.request_started orelse return;
    self.first_token_traced = true;
    const tracer = self.tracer orelse return;
    const ms: i64 = @intCast(@max(0, started.untilNow(self.io, .awake).toMilliseconds()));
    tracer.firstToken(self.label, self.sub, self.provider.model, ms);
}
