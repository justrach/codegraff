"""Held-out checks for cookie-store (not copied into the sandbox)."""
import os
import sys

sys.path.insert(0, os.getcwd())
from cookie_store import CookieStore, CookieConflict  # noqa: E402


def main():
    s = CookieStore()
    s.set("x", "1", domain="Ex.COM", path="/")
    assert s.header_for("ex.com", "/", True) == "x=1"
    assert s.header_for("www.ex.com", "/", True) == "x=1"
    assert s.header_for("evil.com", "/", True) == ""

    s = CookieStore()
    s.set("p", "1", domain="ex.com", path="/docs")
    assert s.header_for("ex.com", "/docs", True) == "p=1"
    assert s.header_for("ex.com", "/docs/", True) == "p=1"
    assert s.header_for("ex.com", "/docsX", True) == ""

    s = CookieStore(max_cookies=2, max_cookies_per_domain=1)
    s.set("a", "1", domain="a.com")
    s.set("b", "2", domain="a.com")
    names = [c.name for c in s.cookies_for("a.com", "/", True)]
    assert names == ["b"], names

    s = CookieStore()
    s.extract("ex.com", "/", "gone=1; Path=/", https=True)
    s.extract("ex.com", "/", "gone=; Path=/; Max-Age=0", https=True)
    assert s.header_for("ex.com", "/", True) == ""

    s = CookieStore()
    s.extract("ex.com", "/", "bad=1; Domain=", https=True)
    assert s.header_for("ex.com", "/", True) == ""

    s = CookieStore()
    s.extract("ex.com", "/", "__Secure-tok=z; Secure", https=False)
    assert s.header_for("ex.com", "/", False) == ""
    s.extract("ex.com", "/", "__Secure-tok=z; Secure", https=True)
    assert s.header_for("ex.com", "/", True) == "__Secure-tok=z"
    assert s.header_for("ex.com", "/", False) == ""

    s = CookieStore()
    s.set("sec", "1", domain="ex.com", path="/", secure=True)
    assert s.header_for("ex.com", "/", False) == ""
    assert s.header_for("ex.com", "/", True) == "sec=1"

    s = CookieStore()
    s.set("n", "1", domain="a.com", path="/")
    s.set("n", "2", domain="b.com", path="/")
    try:
        _ = s["n"]
        raise SystemExit("expected CookieConflict")
    except CookieConflict:
        pass

    print("HIDDEN_OK")


if __name__ == "__main__":
    main()
