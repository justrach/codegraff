# Validated error accumulation (DeepSWE `returns-validated-error-accumulation`, distilled)

`validated.py` must expose `Valid`, `Invalid`, `Validated` (alias of the
union behavior via classmethods on either). `Validated.from_validated(v)`
returns the same Valid or Invalid instance; `Validated.from_failure(err)`
returns `Invalid((err,))`. The concrete representation of the alias is unrestricted.

- `Valid(x)` and `Invalid(errors)` where `Invalid` stores errors as an
  immutable tuple. `Invalid.from_failure(err)` wraps a single error in a
  1-tuple.
- `bind(fn)` short-circuits: `Invalid` stays `Invalid` (fn not called);
  `Valid` calls `fn` and returns its Validated.
- `apply(other)` is applicative. Two `Invalid`s concatenate **self then
  other**, left to right. `Valid` + `Invalid` → that `Invalid`.
  `Valid(f).apply(Valid(x))` → `Valid(f(x))`.
- `swap()`: `Valid(x)` → `Invalid((x,))`; `Invalid(errs)` → `Valid(errs)`.
- `from_validated(v)` returns the same instance.
- `alt(fn)` on `Invalid` maps `fn` over each error; on `Valid` is identity.
- `__match_args__` is `("value",)` for Valid and `("errors",)` for Invalid.
- `combine(a, b, fn)` applicative-combines two containers with `fn(a,b)`.
- `combine_n(items, fn)` applies `fn` to N inner values, accumulating
  every error if any item is Invalid.

An `Invalid(())` still represents failure: `combine` and `combine_n` must
return Invalid without calling `fn`, even when the accumulated tuple is empty.
`from_failure` and `Valid.swap` wrap collection-valued errors/values as a single
item rather than flattening them.
