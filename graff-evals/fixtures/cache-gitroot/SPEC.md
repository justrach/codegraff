# Cache affinity is the git root (CodeGraff cache-affinity-gitroot, distilled)

`affinity.py` must expose:

- `git_root_of(cwd) -> str | None` — walk parents of `cwd` until a `.git`
  file or directory is found. Return that directory's absolute path, or
  `None` if the walk hits the filesystem root with no `.git`.
- `affinity_seed(cwd) -> str` — `git_root_of(cwd)` when the tree is a repo;
  otherwise the constant `SCRATCH_SEED` (`"graff-scratch"`). Never the leaf
  cwd of a scratch tree.
- `cache_key(cwd) -> str` — sha256 hex of `salt + affinity_seed(cwd)`
  (`salt` is `CACHE_SALT`).

Two nested directories under the same repo **must share** one seed (and
therefore one key). A temp directory with no `.git` must not use its cwd
as the seed — that is the eval-sandbox cold-cache bug.
