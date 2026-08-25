from cookie_store import CookieStore, CookieConflict


def test_basic():
    s = CookieStore()
    s.set("sid", "abc", domain="ex.com", path="/")
    assert s["sid"] == "abc"
    assert s.header_for("ex.com", "/", True) == "sid=abc"


def test_path_is_not_a_string_prefix():
    s = CookieStore()
    s.set("x", "1", domain="ex.com", path="/sub")
    assert s.header_for("ex.com", "/sub", True) == "x=1"
    assert s.header_for("ex.com", "/sub/page", True) == "x=1"
    assert s.header_for("ex.com", "/submarine", True) == ""


def test_evict_oldest_global():
    s = CookieStore(max_cookies=2)
    s.set("a", "1")
    s.set("b", "2")
    s.set("c", "3")
    names = [c.name for c in s.cookies_for("any", "/", True)]
    assert names == ["b", "c"], names


def test_conflict():
    s = CookieStore()
    s.set("n", "1", domain="a.com", path="/")
    s.set("n", "2", domain="b.com", path="/")
    try:
        _ = s["n"]
    except CookieConflict:
        return
    raise AssertionError("expected CookieConflict")


if __name__ == "__main__":
    test_basic()
    test_path_is_not_a_string_prefix()
    test_evict_oldest_global()
    test_conflict()
    print("OK")
