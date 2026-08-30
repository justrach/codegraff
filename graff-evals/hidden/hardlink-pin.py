"""Held-out checks for hardlink-pin (not copied into the sandbox)."""
import os
import stat
import sys
import tempfile

sys.path.insert(0, os.getcwd())
from pin import pin_executable  # noqa: E402


def main():
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "live")
        kit = os.path.join(td, "kit")
        os.mkdir(kit)
        with open(src, "wb") as f:
            f.write(b"x" * 64)
        os.chmod(src, 0o640)
        first = pin_executable(src, kit, "graff-pinned")
        again = pin_executable(src, kit, "graff-pinned")
        assert first == again
        assert os.stat(src).st_ino == os.stat(again).st_ino
        assert os.stat(again).st_nlink >= 2
        assert stat.S_IMODE(os.stat(src).st_mode) == 0o640
        assert os.path.getsize(src) == 64
    print("hidden OK")


if __name__ == "__main__":
    main()
