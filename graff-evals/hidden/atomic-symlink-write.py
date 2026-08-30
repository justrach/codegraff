"""Held-out checks for atomic-symlink-write (not copied into the sandbox)."""
import os
import sys
import tempfile

sys.path.insert(0, os.getcwd())
from atomic_write import replace_file  # noqa: E402


def main():
    with tempfile.TemporaryDirectory() as td:
        a = os.path.join(td, "a.json")
        b = os.path.join(td, "b.json")
        c = os.path.join(td, "c.json")
        with open(c, "w") as f:
            f.write("old")
        os.symlink("c.json", b)
        os.symlink("b.json", a)
        replace_file(a, "new")
        assert os.path.islink(a) and os.readlink(a) == "b.json"
        assert os.path.islink(b) and os.readlink(b) == "c.json"
        assert not os.path.islink(c)
        assert open(c).read() == "new"

    with tempfile.TemporaryDirectory() as td:
        missing = os.path.join(td, "gone.json")
        link = os.path.join(td, "settings.json")
        os.symlink("gone.json", link)
        replace_file(link, "created")
        assert os.path.islink(link)
        assert os.readlink(link) == "gone.json"
        assert open(missing).read() == "created"

    with tempfile.TemporaryDirectory() as td:
        x = os.path.join(td, "x")
        y = os.path.join(td, "y")
        os.symlink("y", x)
        os.symlink("x", y)
        try:
            replace_file(x, "nope")
        except (OSError, ValueError):
            pass
        else:
            raise SystemExit("cycle must raise")
        assert os.readlink(x) == "y"
        assert os.readlink(y) == "x"

    print("hidden OK")


if __name__ == "__main__":
    main()
