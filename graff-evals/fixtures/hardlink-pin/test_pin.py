import os
import stat
import tempfile

from pin import pin_executable


def test_same_inode_on_one_fs():
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "graff")
        kit = os.path.join(td, "kit")
        os.mkdir(kit)
        with open(src, "wb") as f:
            f.write(b"exe")
        os.chmod(src, 0o700)
        dest = pin_executable(src, kit, "graff-pinned")
        assert os.path.isfile(dest)
        assert os.stat(src).st_ino == os.stat(dest).st_ino
        assert os.stat(dest).st_nlink >= 2
        assert stat.S_IMODE(os.stat(src).st_mode) == 0o700


if __name__ == "__main__":
    test_same_inode_on_one_fs()
    print("OK")
