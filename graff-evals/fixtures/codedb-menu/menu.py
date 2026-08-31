"""codedb advertised surface — incomplete. Fix the SPEC.md contract."""

ADVERTISED = ["context", "around", "callpath", "list_dir", "status"]
HOPS = ["search", "symbol", "callers", "find", "outline", "read"]


def menu():
    # BUG: hop verbs ride the catalog listing (ADR 0019).
    return ADVERTISED + HOPS


def allowed(sub):
    return sub in ADVERTISED


def usage():
    return "codedb <command> — " + " · ".join(ADVERTISED + HOPS)
