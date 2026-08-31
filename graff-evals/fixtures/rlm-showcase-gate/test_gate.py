from gate import should_showcase


def test_cli_and_wide_native():
    assert should_showcase(cli=True) is True
    assert should_showcase(native_batch=["read_file", "codedb", "bash"]) is False
    assert should_showcase(native_batch=["read_file", "codedb", "bash", "webfetch"]) is True


def test_mcp_fanout_and_context():
    mcp = ["mcp__linear__list_comments"] * 4
    assert should_showcase(mcp_batch=mcp) is False
    assert should_showcase(context=3999, compact_at=8000) is False
    assert should_showcase(context=4000, compact_at=8000) is True


if __name__ == "__main__":
    test_cli_and_wide_native()
    test_mcp_fanout_and_context()
    print("OK")
