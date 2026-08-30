from join import defer_mcp_join, first_request_join, oneshot_skips_imported


def test_defer_and_imported():
    assert defer_mcp_join(True, False) is True
    assert defer_mcp_join(True, True) is False
    assert defer_mcp_join(False, False) is False
    assert oneshot_skips_imported(True, True, 0) is True
    assert oneshot_skips_imported(True, True, 1) is False
    assert oneshot_skips_imported(True, False, 0) is False
    assert oneshot_skips_imported(False, True, 0) is False


def test_first_request_skips_once():
    skipped = [False]
    assert first_request_join(0, skipped) == "none"
    assert skipped == [False]
    assert first_request_join(2, skipped) == "skip"
    assert skipped == [True]
    assert first_request_join(2, skipped) == "join"


if __name__ == "__main__":
    test_defer_and_imported()
    test_first_request_skips_once()
    print("OK")
