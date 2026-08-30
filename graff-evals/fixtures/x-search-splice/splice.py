"""x_search splice — incomplete. Fix the SPEC.md contract."""


def splice(tools, provider, kind, enabled=True):
    out = list(tools)
    # BUG: always appends a catalog-style function, including chat / off.
    out.append({"type": "function", "name": "x_search"})
    return out
