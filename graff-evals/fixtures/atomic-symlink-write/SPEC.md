# Atomic write through a symlink (CodeGraff #685 / #405, distilled)

`atomic_write.py` must expose `replace_file(path, data)`.

`data` is `str` or `bytes`. The function writes a temp file in the *target's*
directory, then renames it into place so a reader sees the whole old file or
the whole new file — never a truncate.

When `path` is a symlink (or a chain of symlinks):

- The named path **stays a symlink**. Do not replace the link with a regular file.
- The write lands on the **final referent**.
- Relative targets are anchored to each link's directory. Do not lexically
  collapse `..` before walking; a `..` after a symlink must traverse the
  symlink first.
- A dangling final target: create that file, leave the symlink in place.
- A cycle (A→B→A) raises `OSError` / `ValueError` and changes neither link.

A non-symlink path is a normal atomic replace of that file.

The motivating case is a credential-store path: `settings.json` →
`credentials/graff-oauth.json`. Writing the named path must not replace the
symlink with a regular file (that silently orphans the real store).
