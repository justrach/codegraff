from resume import resume, snapshot


def test_restore_cursor_and_inbox():
    snap = snapshot(42, ["wake-1", "wake-2"])
    got = resume(snap)
    assert got["cursor"] == 42
    assert got["inbox"] == ["wake-1", "wake-2"]
    assert got["history"] == []


if __name__ == "__main__":
    test_restore_cursor_and_inbox()
    print("OK")
