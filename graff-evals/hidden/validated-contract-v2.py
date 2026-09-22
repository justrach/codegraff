#!/usr/bin/env python3
"""Independent held-out checks for the explicit validated-contract-v2 SPEC.
Run with --source PATH; no dependence on visible test implementations.
"""
import argparse
import hashlib
import json
from pathlib import Path
import types


def audit(source):
    data = source.read_bytes()
    module = types.ModuleType("validated_contract_subject")
    exec(compile(data, str(source), "exec"), module.__dict__)
    results = []

    def check(name, fn):
        try:
            fn()
            results.append({"name": name, "passed": True})
        except Exception as exc:
            results.append({"name": name, "passed": False,
                            "error": f"{type(exc).__name__}: {exc}"})

    def require(condition, reason):
        if not condition:
            raise AssertionError(reason)

    V, I = module.Valid, module.Invalid
    check("required_Validated_export", lambda: require(hasattr(module, "Validated"), "Validated export missing"))

    def alias_classmethods():
        alias = module.Validated
        for item in (V(3), I(("e",))):
            require(alias.from_validated(item) is item, "Validated.from_validated must preserve identity")
        error = ["one error"]
        out = alias.from_failure(error)
        require(isinstance(out, I), "Validated.from_failure must produce Invalid")
        require(out.errors == (error,), "Validated.from_failure must wrap one error")
    check("Validated_classmethods", alias_classmethods)

    def immutable_storage():
        errors = ["a", "b"]
        out = I(errors)
        errors.append("c")
        require(isinstance(out.errors, tuple) and out.errors == ("a", "b"), "errors must be a tuple snapshot")
    check("immutable_error_storage", immutable_storage)

    def atomic_failure():
        for error in (["a", "b"], ("a", "b"), None, "ab"):
            out = I.from_failure(error)
            require(out.errors == (error,), "from_failure must wrap rather than flatten")
    check("from_failure_wraps_collection_as_one_error", atomic_failure)

    def swap():
        for value in ([1, 2], (1, 2), None):
            require(V(value).swap().errors == (value,), "swap must wrap the entire value")
        require(I(()).swap() == V(()), "empty errors swap to Valid empty tuple")
    check("swap_collection_and_empty_tuple", swap)

    def identities():
        def forbidden(*_):
            raise AssertionError("callback must not run")
        valid, invalid = V(1), I(())
        require(valid.alt(forbidden) is valid, "Valid.alt is identity")
        require(isinstance(invalid.bind(forbidden), I), "Invalid.bind stays Invalid")
        for cls in (V, I):
            for item in (valid, invalid):
                require(cls.from_validated(item) is item, "from_validated must return identical instance")
        require(invalid.alt(forbidden).errors == (), "alt on empty errors stays empty")
        require(I(("a", "b")).alt(str.upper).errors == ("A", "B"), "alt maps each error")
    check("bind_alt_and_conversion_identities", identities)

    def applicative():
        require(V.__match_args__ == ("value",), "Valid match declaration")
        require(I.__match_args__ == ("errors",), "Invalid match declaration")
        require(V(6).bind(lambda x: V(x - 2)) == V(4), "Valid.bind calls function")
        require(V(lambda x: x + 11).apply(V(5)) == V(16), "valid applicative")
        match V(27):
            case V(value):
                require(value == 27, "Valid match argument")
        match I(("pattern",)):
            case I(errors):
                require(errors == ("pattern",), "Invalid match argument")
        require(I(("a", "b")).apply(I(("c", "d"))).errors == ("a", "b", "c", "d"), "error ordering")
        require(I(()).apply(I(("x",))).errors == ("x",), "empty left errors concatenate")
        require(I(("x",)).apply(I(())).errors == ("x",), "empty right errors concatenate")
        require(isinstance(I(()).apply(V(9)), I), "Invalid apply Valid remains Invalid")
        require(isinstance(V(lambda x: x).apply(I(())), I), "Valid apply empty Invalid remains Invalid")
    check("applicative_empty_errors_and_order", applicative)

    def combine_short_circuit():
        def forbidden(*_):
            raise AssertionError("combination callback ran with Invalid input")
        for a, b in ((I(()), V(1)), (V(1), I(())), (I(()), I(()))):
            require(isinstance(module.combine(a, b, forbidden), I), "combine must preserve Invalid")
        for items in ((I(()),), (V(1), I(())), (I(()), I(()))):
            out = module.combine_n(items, forbidden)
            require(isinstance(out, I) and out.errors == (), "any Invalid yields Invalid, including zero errors")
    check("combine_and_combine_n_empty_Invalid_short_circuit", combine_short_circuit)

    def combine_n():
        require(module.combine_n((V(2), V(3), V(4)), lambda a, b, c: a * b + c) == V(10), "N values/order")
        out = module.combine_n((I(("a", "b")), V(2), I(("c",))), lambda *_: None)
        require(isinstance(out, I) and out.errors == ("a", "b", "c"), "all errors left to right")
    check("combine_n_success_and_order", combine_n)
    return {"source": str(source), "sha256": hashlib.sha256(data).hexdigest(),
            "contract_version": "validated-contract-v2", "checks": results,
            "contract_pass": all(r["passed"] for r in results)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = audit(args.source.resolve())
    except Exception as exc:
        print(json.dumps({"audit_error": f"{type(exc).__name__}: {exc}", "contract_pass": False}))
        return 2
    print(json.dumps(result, indent=2))
    return 0 if result["contract_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
