"""Held-out checks for stall-warn."""
import os
import sys

sys.path.insert(0, os.getcwd())
from stall_notice import GIVE_UP, stall_notice  # noqa: E402


def main():
    assert stall_notice(-1) == GIVE_UP
    assert stall_notice(3) is None
    notices = [stall_notice(left) for left in (2, 1, 0)]
    assert notices == [None, None, GIVE_UP]
    print("hidden OK")


if __name__ == "__main__":
    main()
