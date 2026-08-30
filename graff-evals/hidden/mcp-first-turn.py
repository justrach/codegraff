"""Held-out checks for mcp-first-turn."""
import os
import sys

sys.path.insert(0, os.getcwd())
from join import defer_mcp_join, first_request_join, oneshot_skips_imported  # noqa: E402


def main():
    assert defer_mcp_join(False, True) is False
    assert oneshot_skips_imported(True, True, 3) is False
    skipped = [False]
    assert first_request_join(1, skipped) == "skip"
    assert first_request_join(0, skipped) == "none"
    assert skipped == [True]
    assert first_request_join(4, skipped) == "join"
    print("hidden OK")


if __name__ == "__main__":
    main()
