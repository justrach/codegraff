# 0050. DeepSeek flash default is thinking off

Status: accepted 2026-08-29

## Context

ADR 0046 maps flash default `.medium` to `reasoning_effort: low`.
That stops GLM/Gemini thinking novels. DeepSeek V4 is different:
thinking is **on at high** unless the request carries
`thinking: {type: disabled}`. Official docs: `low` still thinks;
it only lowers CoT. `none` is a 400 on Chat Completions.

DeepSeek flash SWE after ADR 0049: graff **5/6 in 362s** vs OpenCode
**5/6 in 261s**. The 100s gap is not catalog or heap. cookie-store
call 2 was **75s / 1.9MB** of `reasoning_content` at `low`. An earlier
A/B without that dump was 89s / 9 calls (OpenCode 76s / 9). Pi sets
`reasoning: false`. OpenCode omits the field (default = thinking on);
it still won on a no-dump draw. Do not steal Pi's four-tool catalog
or OpenCode's ~1G heap.

## Decision

DeepSeek family (native `deepseek`, or a `deepseek*` model on
codegraff/fireworks) sends `thinking.type=disabled` when the wire
effort is `low` (flash default). `/effort high` (and any non-low)
sends `type=enabled` plus that effort. GLM keeps `low` only —
`type=disabled` still thinks there (ADR 0046). Do not shrink the
keep-list.

## Consequences

- Flash SWE wall is generation without CoT dumps, not Zig vs JS.
- `/effort` remains the only way thinking comes back (no auto-flip).
- Revisit if a named DeepSeek flash pin needs default thinking.
