import os
from config import load_config, ConfigParseError


def test_json_flatten_and_kebab(tmp_path=None):
    os.makedirs("cfg", exist_ok=True)
    open("app.json", "w").write('{"retry-count": 3, "db": {"host": "h"}}')
    got = load_config("app")
    assert got.get("retryCount") == 3, got
    assert got.get("db.host") == "h", got


def test_first_file_only():
    os.makedirs("a", exist_ok=True)
    os.makedirs("b", exist_ok=True)
    open("a/app.json", "w").write('{"x": 1}')
    open("b/app.json", "w").write('{"x": 2, "y": 9}')
    got = load_config("app", search_paths=["a", "b"], merge_configs=False)
    assert got.get("x") == 1, got
    assert "y" not in got, got


def test_cli_beats_env_beats_config():
    open("app.json", "w").write('{"n": 1, "flag": false}')
    got = load_config("app", cli={"n": 7}, env={"n": 5, "flag": True})
    assert got["n"] == 7, got
    assert got["flag"] is True, got


def test_rc_comments():
    open(".apprc", "w").write('# hi\nname="Ada Lovelace"\n\ncount=2\n')
    # no json so rc is used
    try:
        os.remove("app.json")
    except FileNotFoundError:
        pass
    got = load_config("app")
    assert got.get("name") == "Ada Lovelace", got
    assert got.get("count") == 2, got
    assert "#" not in "".join(map(str, got.keys())), got


if __name__ == "__main__":
    test_json_flatten_and_kebab()
    test_first_file_only()
    test_cli_beats_env_beats_config()
    test_rc_comments()
    print("OK")
