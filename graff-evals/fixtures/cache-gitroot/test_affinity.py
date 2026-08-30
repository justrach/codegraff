import os
import tempfile

from affinity import SCRATCH_SEED, affinity_seed, cache_key, git_root_of


def test_nested_dir_shares_git_root():
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, ".git"))
        nest = os.path.join(td, "graff-evals", ".sandboxes", "run-1")
        os.makedirs(nest)
        root = os.path.abspath(td)
        assert git_root_of(nest) == root
        assert affinity_seed(nest) == root
        assert affinity_seed(td) == root
        assert cache_key(nest) == cache_key(td)


def test_scratch_tree_is_not_cwd():
    with tempfile.TemporaryDirectory() as td:
        assert git_root_of(td) is None
        assert affinity_seed(td) == SCRATCH_SEED
        other = os.path.join(td, "leaf")
        os.makedirs(other)
        assert affinity_seed(other) == SCRATCH_SEED
        assert cache_key(other) == cache_key(td)


if __name__ == "__main__":
    test_nested_dir_shares_git_root()
    test_scratch_tree_is_not_cwd()
    print("OK")
