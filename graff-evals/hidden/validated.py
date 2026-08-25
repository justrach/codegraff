"""Held-out checks for validated."""
import os
import sys

sys.path.insert(0, os.getcwd())
from validated import Invalid, Valid, combine, combine_n  # noqa: E402


def main():
    v = Valid(1)
    assert Valid.from_validated(v) is v
    i = Invalid.from_failure("z")
    assert i.errors == ("z",)
    assert i.alt(str.upper).errors == ("Z",)

    left = Invalid(("a", "b"))
    right = Invalid.from_failure("c")
    assert left.apply(right).errors == ("a", "b", "c")

    f = Valid(lambda x: x * 2)
    assert f.apply(Valid(4)) == Valid(8)
    assert f.apply(Invalid.from_failure("n")).errors == ("n",)

    assert Valid("x").swap().errors == ("x",)
    assert Invalid(("e1", "e2")).swap() == Valid(("e1", "e2"))

    got = combine(Invalid.from_failure("p"), Invalid.from_failure("q"), lambda a, b: a)
    assert got.errors == ("p", "q")

    match Valid(9):
        case Valid(value):
            assert value == 9
        case _:
            raise SystemExit("match Valid")
    match Invalid(("e",)):
        case Invalid(errors):
            assert errors == ("e",)
        case _:
            raise SystemExit("match Invalid")

    print("HIDDEN_OK")


if __name__ == "__main__":
    main()
