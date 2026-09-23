# 0192. MiMo thinking is Off or On

Status: accepted 2026-09-23

## Context

MiMo's [Responses API](https://mimo.mi.com/docs/en-US/api/chat/responses)
documents `reasoning.effort=none` as Off and every positive effort as the same
On mode. Its [Chat API](https://mimo.mi.com/docs/en-US/api/chat/openai-api)
controls the same choice with `thinking.type=disabled|enabled`. Showing Low,
Medium, and High as distinct MiMo intensities claims a control the API does not
provide. The generic flash default-to-low rule in ADR 0046 applies to other
models; for MiMo, Low still means On.

## Decision

Expose only Off (`none`) and On (`high`) for MiMo on the direct Xiaomi and
Codegraff gateway routes in the REPL, ACP, and desktop model controls. An
unrelated provider's MiMo-named alias retains its existing controls until its
wire format is verified. Existing saved or typed positive effort values still mean On;
they display as On and use the canonical wire value. Direct and gateway Chat
requests send `thinking.type`; Responses requests use `reasoning.effort`. Keep
assistant `reasoning_content` alongside tool calls in subsequent Chat requests.

An explicit Off selection, including a worker override, is rejected on other
routes before inference. If a model switch
leaves Off unsupported, reset to Medium with a notice; loading a stale saved
Off setting for another model does the same before inference.

## Consequences

The UI no longer promises a MiMo reasoning-intensity ladder. Existing positive
preferences continue to run with thinking enabled. A model switch may reset
the global effort setting, and the notice makes that change visible.
