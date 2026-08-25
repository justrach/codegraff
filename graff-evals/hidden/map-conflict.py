"""Held-out checks for map-conflict."""
import os
import sys

sys.path.insert(0, os.getcwd())
from doc import Doc, MapConflictError  # noqa: E402


def main():
    d = Doc(map_conflict_policy="collect")
    m = d.get_map("room")
    d.transact(lambda: (m.set("a", 1), m.delete("a"), m.set("b", {"nested": True}), m.set("b", 2)))
    cs = d.get_map_conflicts()
    types = {c["key"]: c["type"] for c in cs}
    assert types["a"] == "delete-set", types
    assert types["b"] == "ambiguous", types
    s = d.get_map_conflict_summary()
    assert s["count"] == 2
    assert s["byKey"]["a"] == 1

    d = Doc(map_conflict_policy="error")
    m = d.get_map("m")
    try:
        d.transact(lambda: (m.set("x", 1), m.delete("x")))
        raise SystemExit("expected error")
    except MapConflictError as e:
        assert isinstance(e.conflicts, list) and e.conflicts
    assert m.get("x") is None

    d = Doc(map_conflict_policy="allow")
    m = d.get_map("m")
    d.transact(lambda: (m.set("k", 1), m.delete("k"), m.set("k", 9)))
    assert m.get("k") == 9
    assert d.get_map_conflicts() == []

    print("HIDDEN_OK")


if __name__ == "__main__":
    main()
