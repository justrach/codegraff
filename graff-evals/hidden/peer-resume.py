"""Held-out checks for peer-resume."""
import os
import sys

sys.path.insert(0, os.getcwd())
from resume import ROOM, resume, snapshot  # noqa: E402


def main():
    snap = snapshot(7, [{"from": "peer", "text": "hi"}])
    got = resume(snap)
    assert got["cursor"] == 7
    assert got["inbox"] == [{"from": "peer", "text": "hi"}]
    assert got["history"] == []
    for line in ROOM:
        assert line not in got["history"]
    empty = resume(snapshot(0, []))
    assert empty["cursor"] == 0 and empty["inbox"] == [] and empty["history"] == []
    print("hidden OK")


if __name__ == "__main__":
    main()
