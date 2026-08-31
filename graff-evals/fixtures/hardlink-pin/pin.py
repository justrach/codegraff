"""Learn-kit pin — incomplete. Fix the SPEC.md contract."""
import os
import shutil


def pin_executable(source_path, dest_dir, name):
    dest = os.path.join(dest_dir, name)
    if os.path.exists(dest):
        os.remove(dest)
    # BUG: always byte-copy, then chmod the dest (would also chmod a hardlink).
    shutil.copy2(source_path, dest)
    os.chmod(dest, 0o755)
    return dest
