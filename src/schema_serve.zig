//! Embedded documentation for the `graff serve` HTTP bridge, emitted verbatim
//! under the "serve" key of `graff --schema` (the SDK generators read it).
//! Split out of schema.zig, which is at the 600-line cap.

pub const json =
    \\{
    \\  "transport": "HTTP/1.1 (graff serve, default 127.0.0.1:8787); auth via Authorization: Bearer <token> when --token/HARNESS_SERVE_TOKEN is set (required on non-loopback binds)",
    \\  "sequencing": "every streamed event carries a monotonic per-session \"seq\" (1-based, gap-free) as its FIRST field. The bridge persists each forwarded line to .graff/serve/<session_id>.events.jsonl and keeps draining the child into that log even after a client disconnects, so a supervisor that dies mid-turn loses nothing. Reconnect with ?from=N (or {\"resume_from\":N}) to receive persisted events with seq >= N before the live stream continues",
    \\  "resume": "the session id IS the graff session name: the child runs as `graff --json --resume <id>`, autosaving .graff/sessions/<id>.session.json after every turn. A REPLACEMENT serve process on a fresh host POSTs /v1/sessions with {\"session\":\"<id>\"} in the same workspace and the run continues from the last persisted turn, with the event sequence continuing (never restarting) because the counter is persisted alongside the conversation as event_seq",
    \\  "endpoints": [
    \\    {"method": "GET", "path": "/healthz", "description": "liveness + version, no auth"},
    \\    {"method": "GET", "path": "/v1/schema", "description": "this schema document"},
    \\    {"method": "POST", "path": "/v1/sessions", "description": "create OR resume a session (a graff --json child); optional JSON body {\"session\",\"model\",\"subagentProvider\",\"subagentModel\",\"allowCrossProviderSubagents\",\"yolo\",\"system_prompt\",\"append_system_prompt\",\"maxToolCalls\",\"maxModelCalls\",\"dedupeToolCalls\"} overrides serve-level defaults. \"session\" (aliases \"session_id\"/\"resume\") names a durable session: 1-64 chars of [A-Za-z0-9._-], not starting with . or -; omitted means a fresh 16-hex name. Responds {\"session_id\":\"<name>\",\"resumed\":<bool>,\"last_seq\":<N>} - resumed says a session file already existed, last_seq is where the persisted event tape ends (reconnect with ?from=last_seq+1)"},
    \\    {"method": "POST", "path": "/v1/sessions/{id}", "description": "body is ONE stdio-protocol request object (user / review / set_system_prompt / set_model / compact / set_mode / set_agent / set_effort / set_fast / score / answer); non-answer requests stream application/x-ndjson events until the request's terminal event (turn/error, or the request-specific ack); answer requests return a JSON ack while the original user stream continues; one non-answer request in flight per session at a time. ?from=N or {\"resume_from\":N} replays persisted events with seq >= N before the live stream. {\"type\":\"reattach\"} sends nothing to the child and only replays+follows, so it is safe while another connection is mid-turn"},
    \\    {"method": "GET", "path": "/v1/sessions/{id}/events?from=N", "description": "reconnect: replay persisted events with seq >= N (default 1), then keep following the log live while a request is in flight, ending at that request's terminal event. Takes no protocol lock and never writes to the child, and works for a session this process never spawned as long as its event log is in the workspace"},
    \\    {"method": "DELETE", "path": "/v1/sessions/{id}", "description": "graceful close: waits for any in-flight request, then EOFs the child's stdin. The session file and the event log stay on disk, so the id remains resumable"}
    \\  ]
    \\}
;
