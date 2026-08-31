"""Held-out checks for rlm-showcase-gate."""
import os
import sys

sys.path.insert(0, os.getcwd())
from gate import should_showcase  # noqa: E402


def main():
    assert should_showcase() is False
    assert should_showcase(context=800, compact_at=160_000) is False
    assert should_showcase(native_batch=["a", "b", "c", "d", "e"]) is True
    assert should_showcase(mcp_batch=["m"] * 8, context=0) is False
    print("hidden OK")


if __name__ == "__main__":
    main()
