from splice import splice


def test_xai_responses_splices_hosted():
    tools = [{"type": "function", "name": "bash"}]
    got = splice(tools, "xai", "responses", enabled=True)
    assert any(t.get("type") == "x_search" for t in got)
    assert not any(t.get("name") == "x_search" for t in got)


def test_opt_out_and_chat_leave_tools():
    tools = [{"type": "function", "name": "bash"}]
    assert splice(tools, "xai", "responses", enabled=False) == tools
    assert splice(tools, "xai", "chat", enabled=True) == tools
    assert splice(tools, "openai", "responses", enabled=True) == tools


if __name__ == "__main__":
    test_xai_responses_splices_hosted()
    test_opt_out_and_chat_leave_tools()
    print("OK")
