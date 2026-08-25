"""Held-out checks for label-sort."""
import os
import sys

sys.path.insert(0, os.getcwd())
from label_sort import sort_labels  # noqa: E402


def main():
    got = sort_labels(["  b", "  a", "1", "v1.0.0", "10s", "1Ki", "::1", "10.0.0.1", "zzz"])
    assert got[:2] == ["  a", "  b"], got
    assert got[2] == "1", got
    assert got[3] == "10s", got
    assert got[4] == "1Ki", got
    assert got[5] == "v1.0.0", got
    assert got[6] == "10.0.0.1", got
    assert got[7] == "::1", got
    assert got[8] == "zzz", got

    got = sort_labels(["1e", "10", "NaN"])
    assert got[0] == "10", got
    assert set(got[1:]) == {"1e", "NaN"}

    got = sort_labels(["+2", "2"])
    assert got == ["+2", "2"] or got == ["2", "+2"]
    # equal numeric value → natural tie-break
    assert sort_labels(["2", "+2"])[0] in ("+2", "2")
    assert _natural_first("+2", "2")

    print("HIDDEN_OK")


def _natural_first(a, b):
    got = sort_labels([b, a])
    # "+2" < "2" lexicographically after equal numeric
    return got == ["+2", "2"]


if __name__ == "__main__":
    main()
