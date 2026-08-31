import os
import tempfile

from atomic_write import replace_file


def test_plain_file():
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "cred.json")
        with open(path, "w") as f:
            f.write('{"old":1}')
        replace_file(path, '{"new":2}')
        assert open(path).read() == '{"new":2}'
        assert not os.path.islink(path)


def test_relative_symlink_keeps_link():
    with tempfile.TemporaryDirectory() as td:
        real = os.path.join(td, "real.json")
        link = os.path.join(td, "settings.json")
        with open(real, "w") as f:
            f.write('{"old":1}')
        os.symlink("real.json", link)
        replace_file(link, '{"new":2}')
        assert os.path.islink(link), "settings.json must remain a symlink"
        assert os.readlink(link) == "real.json"
        assert open(real).read() == '{"new":2}'
        assert open(link).read() == '{"new":2}'


def test_credential_store_symlink():
    """settings.json → credentials/graff-oauth.json must stay a link."""
    with tempfile.TemporaryDirectory() as td:
        cred_dir = os.path.join(td, "credentials")
        os.mkdir(cred_dir)
        real = os.path.join(cred_dir, "graff-oauth.json")
        link = os.path.join(td, "settings.json")
        with open(real, "w") as f:
            f.write('{"old":1}')
        os.symlink("credentials/graff-oauth.json", link)
        replace_file(link, '{"new":2}')
        assert os.path.islink(link), "settings.json must remain a symlink"
        assert os.readlink(link) == "credentials/graff-oauth.json"
        assert open(real).read() == '{"new":2}'


if __name__ == "__main__":
    test_plain_file()
    test_relative_symlink_keeps_link()
    test_credential_store_symlink()
    print("OK")
