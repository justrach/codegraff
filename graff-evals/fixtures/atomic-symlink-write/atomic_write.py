"""Atomic file replace — incomplete. Fix the SPEC.md contract."""
import os
import tempfile


def replace_file(path, data):
    raw = data if isinstance(data, bytes) else data.encode()
    dest = os.path.abspath(path)
    directory = os.path.dirname(dest) or "."
    fd, tmp = tempfile.mkstemp(prefix=".replace-", dir=directory)
    try:
        os.write(fd, raw)
        os.close(fd)
        fd = None
        # BUG: rename replaces a symlink entry instead of its referent.
        os.replace(tmp, dest)
    except Exception:
        if fd is not None:
            os.close(fd)
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
