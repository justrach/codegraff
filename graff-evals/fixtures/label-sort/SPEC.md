# Typed label sort (DeepSWE `prometheus-typed-label-sorting`, distilled)

`label_sort.py` must expose `sort_labels(values: list[str]) -> list[str]`.

Values with **leading whitespace** are never parsed as typed. They sort
before every other value; within that group, use natural sort of the
original strings.

Then order typed classes as: `+Inf` / `Infinity`, finite numeric, `-Inf`,
duration (`10s`, `2ms`, `1h`), bytes (`10Ki`, `1Mi`, `3B`), semantic
version (`1.2.3` or `v1.2.3`), IPv4, IPv6, then untyped natural strings.

Numeric parsing accepts an optional leading `+` and scientific exponents.
A bare exponent (`1e`) is not numeric. `NaN` is not numeric (untyped).

IPv4 sorts before IPv6. When two parsed typed values compare equal, break
ties by natural order of the original strings. Empty strings are untyped.

Natural order compares digit runs numerically and intervening text spans
lexicographically, case-sensitively. Keep empty text spans, including the
span before a leading digit. Text spans sort before digit runs if their
positions differ in type. If these keys are equal, preserve input order.
Thus equal numeric values sort as `2`, `+2` (empty prefix before `+`), and
`1e2`, `100` (first digit run 1 before 100).
