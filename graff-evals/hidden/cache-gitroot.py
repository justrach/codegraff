"""Held-out checks for cache-gitroot."""
import os
import sys
import tempfile

sys.path.insert(0, os.getcwd())
from affinity import SCRATCH_SEED, affinity_seed, git_root_of  # noqa: E402


def main():
    with tempfile.TemporaryDirectory() as td:
        gitfile = os.path.join(td, ".git")
        with open(gitfile, "w") as f:
            f.write("gitdir: /somewhere/else\n")
        leaf = os.path.join(td, "pkg", "src")
        os.makedirs(leaf)
        assert git_root_of(leaf) == os.path.abspath(td)
        assert affinity_seed(leaf) == os.path.abspath(td)

    with tempfile.TemporaryDirectory() as td:
        leaf = os.path.join(td, "nope")
        os.makedirs(leaf)
        assert git_root_of(leaf) is None
        assert affinity_seed(leaf) == SCRATCH_SEED
    print("hidden OK")


if __name__ == "__main__":
    main()
