"""Held-out checks for empty-catalog."""
import json
import os
import sys

sys.path.insert(0, os.getcwd())
from catalog import NATIVE, request_body, tools_json  # noqa: E402


def main():
    extra = ["mcp_search", "bash"]
    got = json.loads(tools_json(showcase=True, extra=extra))
    assert got[0:4] == NATIVE
    assert got[-1] == "mcp_search"
    assert got.count("bash") == 1
    body = json.loads(request_body(showcase=True, extra=extra))
    assert body["tools"] == got
    empty = json.loads(tools_json(showcase=False, extra=[]))
    assert empty == NATIVE
    print("hidden OK")


if __name__ == "__main__":
    main()
