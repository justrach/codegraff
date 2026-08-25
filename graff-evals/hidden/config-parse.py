"""Held-out checks for config-parse."""
import json
import os
import sys

sys.path.insert(0, os.getcwd())
from config import ConfigParseError, load_config  # noqa: E402


def main():
    os.makedirs("p1", exist_ok=True)
    os.makedirs("p2", exist_ok=True)
    open("p1/svc.json", "w").write('{"retry-count": 1, "db": {"port": 0}, "keep": false}')
    open("p2/svc.json", "w").write('{"retry-count": 9, "extra": 4}')
    got = load_config("svc", search_paths=["p1", "p2"], merge_configs=True, cli={"keep": True}, env={"retryCount": 8})
    assert got["retryCount"] == 8, got
    assert got["db.port"] == 0, got
    assert got["keep"] is True, got
    assert got["extra"] == 4, got

    got = load_config("svc", search_paths=["p1", "p2"], merge_configs=False)
    assert got["retryCount"] == 1, got
    assert "extra" not in got, got

    open(".svcrc", "w").write("only=1\n# skip=9\n")
    try:
        os.remove("svc.json")
    except FileNotFoundError:
        pass
    got = load_config("svc", search_paths=["."])
    assert got.get("only") == 1, got
    assert "skip" not in got, got

    open("bad.json", "w").write("{not json")
    try:
        load_config("bad")
        raise SystemExit("expected ConfigParseError")
    except ConfigParseError:
        pass

    print("HIDDEN_OK")


if __name__ == "__main__":
    main()
