"""Held-out checks for codedb-menu."""
import os
import sys

sys.path.insert(0, os.getcwd())
from menu import HOPS, allowed, menu, usage  # noqa: E402


def main():
    assert "callers" not in menu()
    assert "outline" not in usage()
    for hop in HOPS:
        assert allowed(hop), hop
        assert hop not in menu()
    assert allowed("read")
    assert not allowed("delete")
    print("hidden OK")


if __name__ == "__main__":
    main()
