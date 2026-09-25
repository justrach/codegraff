# ACP compatibility

Graff implements ACP wire protocol **v1**. The upstream repository identifies
v1 as stable; v2 is a draft and is not a compatibility target for this release.
Protocol versions are negotiated through `initialize.protocolVersion`, not
inferred from SDK package versions.

References:

- [Upstream versioning](https://github.com/agentclientprotocol/agent-client-protocol#versioning)
- [Stable v1 schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v1/schema.json)
- [Protocol documentation](https://agentclientprotocol.com/protocol/overview)
- [DeepWiki overview](https://deepwiki.com/agentclientprotocol/agent-client-protocol)

The upstream schema is authoritative when a secondary explanation differs.
Optional capabilities must be negotiated; supporting ACP does not mean every
optional feature or draft extension is enabled.

## Release contract

| Surface | Behavior and scope | Regression coverage |
| --- | --- | --- |
| Initialization | Return protocol version 1 and explicit capabilities. Clients must reject a version they cannot speak. | `src/acp_protocol.zig`, `scripts/test-acp-startup.py`, `sdk/ts/acp.test.ts` |
| Authentication | Credential-free initialization is available. Operations requiring a live agent remain authentication-gated. | `scripts/test-acp-preauth.py` |
| Sessions | Create a session in its selected workspace. A live process owns one session; duplicate creation cannot replace its history. Load is advertised only when the live implementation can replay saved history. | `scripts/test-acp-session-load.py`, `scripts/test-acp-released-fixes.py` |
| Prompt lifecycle | Stream session-scoped updates and return the terminal stop reason. Cancellation interrupts the active turn and cannot grant a pending permission. | `scripts/test-acp-failure.py`, `scripts/test-acp-permissions.py` |
| Tool calls | Preserve call identity, status and terminal results. Tool-like prose is not execution evidence. | `src/acp_stream.zig`, `src/agent_steps_tests.zig` |
| Permissions | Send the advertised choices to the active client and await its response. Clients must honor an explicit rejection or cancellation; automatic approval is a separate user setting. | `scripts/test-acp-permissions.py` |
| Effort configuration | Expose supported `thought_level` values in session configuration. Validate setters, return the full option list, and emit `config_option_update` when agent-originated changes alter that state. | `scripts/test-acp-effort-config.py`, `src/acp_config.zig` |
| Configuration timing | Client changes arriving during a prompt are queued for after that turn. An effort-tool result applies on the owning agent thread before the next model request; clients refresh the affected session's controls. | `src/acp_idle.zig`, `src/jev_effort_state.zig`, `apps/native/lib/acp-client-stream.test.ts` |
| Content | Text, resource links and supported embedded text resources are accepted. `image` blocks (`data` + `mimeType`) are accepted and advertised (`promptCapabilities.image`); they reach the next model request when the model accepts images and are skipped otherwise, the same as `@[path]` attachments. Audio is advertised as false. | `src/acp_protocol.zig`, `src/acp_images.zig`, `scripts/test-acp-images.py` |
| Client filesystem and terminals | These are optional negotiated ACP facilities, not a requirement that local harness tools be replaced by client tools. The local tool implementation does not imply support for every client-side method. | Capability negotiation and the upstream v1 schema |
| Usage | Connection usage is a namespaced extension. It preserves unknown totals and is not a standard ACP v1 billing contract. | `scripts/test-acp-usage.py`, ADR 0182 |
| Subagents | The proposed child-session update stream is an opt-in live preview: client `subagents` capability plus `GRAFF_ACP_DRAFT_SUBAGENTS=1`. Explicit `run_in_background:false` foreground children stream separately; the default detached workers retain their parent tool row and `graff/agents` inspection. Child history is not yet replayed on `session/load`. | `scripts/test-acp-subagent-update.py`, ADR 0194 |
| Transport | ACP uses JSON-RPC over stdio. HTTP/2 checks exercise the model request transport behind ACP; they do not redefine ACP as an HTTP/2 protocol. | `scripts/test-acp-http2.py`, `scripts/test-acp-http2-retry.py` |

## Client acceptance checklist

A replacement client should be exercised against the release binary for
initialization, new and loaded sessions, prompt streaming, cancellation,
permission allow/reject/cancel, tool completion and effort configuration.
It must scope every response and notification to the correct session, reject
stale updates after a session is replaced, and retain unknown usage as unknown.
A displayed effort control must track `config_option_update`, including changes
that did not originate from a slash command.

These checks describe the supported contract and its regression coverage.
They are not a claim of exhaustive upstream conformance or support for every
optional capability. Release acceptance also requires the client's own build,
packaging and platform tests; protocol compatibility alone does not validate
a desktop distribution.
