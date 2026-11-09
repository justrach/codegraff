# 0321. OpenAI-model follow-ups steer immediately by default

Status: accepted 2026-11-07

## Context

A plain ACP `session/prompt` sent while a Codex or ChatGPT turn was live waited
in `acp_inbox` until that turn ended. Both routes already support mid-turn
steering: a live Responses WebSocket can carry `response.steer`, and the
non-socket path can supersede the streamed reply and rebuild the request with
the follow-up.

## Decision

For providers `openai`, `codex`, and `chatgpt-new`, plus OpenAI-made models on
`codegraff`, a plain-text prompt sent during a live turn enters the existing
steer queue immediately. The gateway uses model-maker classification, not wire
format: its Claude, Grok and other models retain turn-boundary delivery.
Text-only is required: prompts carrying images or embedded resources stay on
the ordinary queue so their payload is never dropped. Selected slash commands
also stay queued; literal slash prose with explicit
`harness/command: false` may steer. Room posts retain ordinary agent framing.

The steer path acknowledges the ACP request without starting a second turn.
`/followups queue` restores the old next-turn behavior; `/followups immediate`
turns this back on. The choice persists as `followups` in
`.harness/settings.json`. Other providers are unchanged.

The ACP handshake advertises `_meta.steering.supported`, so clients do not hold
follow-ups in their own queue before graff can see them. `_session/steering`
returns `injected` for a live, eligible turn; idle requests, selected commands,
attachments, and unsupported providers return `promptRequired` for normal
`session/prompt` delivery. An explicit Steer action overrides the automatic
queue preference; ordinary `session/prompt` still obeys `/followups queue`.
Session IDs are checked before injection. Harness's
static descriptor and resolved adapter both use step-boundary delivery; the
engine retains the provider- and settings-specific policy.

## Consequences

A follow-up reaches the running model instead of waiting behind it, and the
single root turn remains the owner of the session. If the transport cannot
steer, the existing supersede/rebuild path carries the update. Queueing remains
available as an explicit compatibility setting.
