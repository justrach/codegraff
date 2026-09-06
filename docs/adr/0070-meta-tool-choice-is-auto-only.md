# 0070. Meta tool_choice is auto-only at the source

Status: accepted 2026-09-06

## Context

`muse-spark-1.3` via the Codegraff gateway 400'd on any non-`auto`
`tool_choice`. Meta's error: only `"auto"` is supported; `"none"`,
`"required"`, and named choices are not. The gateway already translates
those (zigrepper `34a4882`): `none` drops tools+choice, `required`/named
become `auto`. A silent rewrite means the harness asked for a forced call
and got a maybe. `reasoning_effort: max` has the same shape (1.3
non-contributor; gateway folds to `xhigh`).

## Decision

Normalise at the source for Meta and any `muse-spark*` model, including
when the seat is the Codegraff gateway. `tool_choice` is always `auto`.
`max`/`ultra` effort becomes `xhigh`. The gateway stays a safety net for
unknown seats. Do not send `required` and hope the gateway rewrites it.

## Consequences

A forced-tool turn on Muse Spark is a request, not a guarantee — the
model may answer in prose. Revisit if Meta adds `required`. #751.
