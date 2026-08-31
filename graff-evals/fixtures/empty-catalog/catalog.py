"""Tool catalog JSON — incomplete. Fix the SPEC.md contract."""
import json

NATIVE = ["read_file", "bash", "codedb", "rlm"]


def tools_json(showcase=False, extra=None):
    # BUG: showcase invalidates the cached catalog and leaves it empty, so the
    # next body prints `"tools":,` (no value).
    if showcase:
        return ""
    names = list(NATIVE)
    for n in extra or []:
        if n not in names:
            names.append(n)
    return json.dumps(names)


def request_body(showcase=False, extra=None):
    raw = tools_json(showcase, extra)
    return '{"tools":' + raw + "}"
