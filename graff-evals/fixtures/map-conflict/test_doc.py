from doc import Doc, MapConflictError


def test_allow_last_write():
    d = Doc(map_conflict_policy="allow")
    m = d.get_map("m")
    d.transact(lambda: (m.set("k", 1), m.set("k", 2)))
    assert m.get("k") == 2
    assert d.get_map_conflicts() == []


def test_collect_records():
    d = Doc(map_conflict_policy="collect")
    m = d.get_map("m")
    d.transact(lambda: (m.set("k", 1), m.set("k", 2)))
    cs = d.get_map_conflicts()
    assert len(cs) == 1, cs
    assert cs[0]["key"] == "k"
    assert cs[0]["type"] == "set-set"
    assert cs[0]["message"]
    assert cs[0]["resolution"]["deterministic"] is True
    s = d.get_map_conflict_summary()
    assert s["count"] == 1
    assert s["byType"]["set-set"] == 1


def test_error_atomic():
    d = Doc(map_conflict_policy="error")
    m = d.get_map("m")
    m.set("ok", 1)
    try:
        d.transact(lambda: (m.set("k", 1), m.set("k", 2)))
        raise AssertionError("expected MapConflictError")
    except MapConflictError as e:
        assert hasattr(e, "conflicts")
        assert e.conflicts
    assert m.get("k") is None, "error policy must roll back the transaction"
    assert m.get("ok") == 1


if __name__ == "__main__":
    test_allow_last_write()
    test_collect_records()
    test_error_atomic()
    print("OK")
