"""MCP first-turn join — incomplete. Fix the SPEC.md contract."""


def defer_mcp_join(yolo, json_mode):
    return yolo


def oneshot_skips_imported(oneshot, lean, project_servers):
    # BUG: lean -p always skips, even with a project .mcp.json (ADR 0029).
    return oneshot and lean


def first_request_join(pending_len, already_skipped):
    # BUG: always join, so the first -p turn waits on the handshake.
    if pending_len == 0:
        return "none"
    return "join"
