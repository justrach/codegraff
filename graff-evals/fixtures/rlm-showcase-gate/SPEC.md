# Late rlm showcase (CodeGraff #633 / ADR 0030, distilled)

`gate.py` must expose `should_showcase(*, cli=False, native_batch=None,
mcp_batch=None, context=0, compact_at=8000) -> bool`.

Showcase `rlm` when **any** of:

- `cli=True` (`--rlm`)
- `native_batch` has **≥ 4** native tool names (wide native batch)
- `context >= compact_at // 2` (50% of compactAt)

Never showcase on MCP fan-out: a 4-wide `mcp_batch` is not a native
batch. `native_batch` / `mcp_batch` default to empty.

`compact_at=8000` → threshold 4000. `context=3999` is still hidden.
