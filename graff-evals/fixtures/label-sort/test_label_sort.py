from label_sort import sort_labels


def test_numeric_and_inf():
    got = sort_labels(["10", "2", "+Inf", "-Inf", "1e2"])
    assert got[0] == "+Inf", got
    assert got[-1] == "-Inf", got
    assert got[1:4] == ["2", "10", "1e2"], got


def test_leading_ws_first():
    got = sort_labels(["10", "  zebra", "  apple", "beta"])
    assert got[0] == "  apple", got
    assert got[1] == "  zebra", got


def test_ipv4_before_ipv6():
    got = sort_labels(["::1", "127.0.0.1"])
    assert got == ["127.0.0.1", "::1"], got


def test_nan_is_untyped():
    got = sort_labels(["NaN", "10", "abc"])
    assert got[0] == "10", got
    assert "NaN" in got[1:]


if __name__ == "__main__":
    test_numeric_and_inf()
    test_leading_ws_first()
    test_ipv4_before_ipv6()
    test_nan_is_untyped()
    print("OK")
