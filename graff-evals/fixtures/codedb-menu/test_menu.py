from menu import ADVERTISED, allowed, menu, usage


def test_menu_is_five_oneshots():
    assert menu() == ADVERTISED
    assert menu() == ["context", "around", "callpath", "list_dir", "status"]
    text = usage()
    assert "context" in text and "list_dir" in text
    assert "search" not in text and "symbol" not in text


def test_hops_callable_update_not():
    assert allowed("callpath")
    assert allowed("search")
    assert allowed("symbol")
    assert not allowed("update")


if __name__ == "__main__":
    test_menu_is_five_oneshots()
    test_hops_callable_update_not()
    print("OK")
