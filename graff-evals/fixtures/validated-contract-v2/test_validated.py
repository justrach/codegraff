from validated import Invalid, Valid, combine, combine_n


def test_from_failure_tuple():
    i = Invalid.from_failure("e")
    assert i.errors == ("e",), i.errors


def test_apply_concat():
    a = Invalid.from_failure("a")
    b = Invalid.from_failure("b")
    got = a.apply(b)
    assert got.errors == ("a", "b"), got.errors


def test_swap_wraps():
    assert Valid(3).swap() == Invalid((3,))
    assert Invalid(("e",)).swap() == Valid(("e",))


def test_bind_short_circuit():
    called = []
    Invalid.from_failure("e").bind(lambda x: called.append(x) or Valid(x))
    assert called == []
    assert Valid(2).bind(lambda x: Valid(x + 1)) == Valid(3)


def test_combine_n():
    got = combine_n((Valid(1), Invalid.from_failure("x"), Invalid.from_failure("y")), lambda a, b, c: a)
    assert got.errors == ("x", "y"), got.errors
    assert combine(Valid(2), Valid(3), lambda x, y: x + y) == Valid(5)


def test_alias_contract():
    from validated import Validated
    for value in (Valid(8), Invalid(("alias",))):
        assert Validated.from_validated(value) is value
    assert Validated.from_failure("failure").errors == ("failure",)


def test_collection_is_one_failure():
    error = ["single", "compound", "error"]
    assert Invalid.from_failure(error).errors == (error,)
    assert Valid(error).swap().errors == (error,)


def test_empty_invalid_never_calls_combiner():
    def forbidden(*args):
        raise AssertionError("combiner called despite Invalid input")
    for items in ((Invalid(()),), (Valid(7), Invalid(()))):
        result = combine_n(items, forbidden)
        assert isinstance(result, Invalid)
        assert result.errors == ()
    assert isinstance(combine(Invalid(()), Valid(7), forbidden), Invalid)


if __name__ == "__main__":
    test_from_failure_tuple()
    test_apply_concat()
    test_swap_wraps()
    test_bind_short_circuit()
    test_combine_n()
    test_alias_contract()
    test_collection_is_one_failure()
    test_empty_invalid_never_calls_combiner()
    print("OK")
