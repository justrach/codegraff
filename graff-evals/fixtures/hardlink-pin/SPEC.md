# Hardlink the learn pin (CodeGraff #687, distilled)

`pin.py` must expose `pin_executable(source_path, dest_dir, name) -> str`.

It places `name` inside `dest_dir` and returns that path.

- Prefer `os.link(source, dest)` so the pin and the live exe share an inode
  (`nlink >= 2`). A 127M byte-copy is the wall tax this contract kills.
- If `dest` already exists, remove it first, then link.
- Do **not** `chmod` the dest. After a hardlink that would also chmod the
  live exe.
- Copy only when `os.link` raises `OSError` (cross-device). The copy must
  still not chmod the dest.
- `source_path` must remain a regular file at the same mode it had before
  the pin.
