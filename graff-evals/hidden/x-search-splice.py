"""Held-out checks for x-search-splice."""
import os
import sys

sys.path.insert(0, os.getcwd())
from splice import splice  # noqa: E402


def main():
    already = [{"type": "x_search"}]
    got = splice(already, "xai", "responses", enabled=True)
    assert sum(1 for t in got if t.get("type") == "x_search") == 1
    empty = splice([], "xai", "responses", enabled=True)
    assert empty == [{"type": "x_search"}]
    assert splice([], "anthropic", "responses", enabled=True) == []
    print("hidden OK")


if __name__ == "__main__":
    main()
