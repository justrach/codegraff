"""rlm showcase gate — incomplete. Fix the SPEC.md contract."""


def should_showcase(*, cli=False, native_batch=None, mcp_batch=None, context=0, compact_at=8000):
    # BUG: any 4-wide batch showcases, including MCP fan-out; no 50% gate.
    batch = list(native_batch or []) + list(mcp_batch or [])
    return cli or len(batch) >= 4 or context > 0
