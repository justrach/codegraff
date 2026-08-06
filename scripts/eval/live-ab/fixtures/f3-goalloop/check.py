#!/usr/bin/env python3
"""Checker for slugify(). Prints a per-case report and a `score: N` line.

Every case must pass for a score of 100.
"""
import sys

sys.path.insert(0, ".")

try:
    from slugify import slugify
except Exception as e:  # pragma: no cover
    print("FATAL: cannot import slugify:", e)
    print("score: 0")
    sys.exit(1)

# (input, expected, which property the case exercises)
CASES = [
    ("Hello World", "hello-world", "lowercase-and-hyphenate"),
    ("Zig Build System", "zig-build-system", "lowercase-and-hyphenate"),
    ("API", "api", "lowercase-and-hyphenate"),
    ("Release Notes 2026", "release-notes-2026", "lowercase-and-hyphenate"),
    ("  Leading And Trailing  ", "leading-and-trailing", "collapse-and-trim"),
    ("Too   Many   Spaces", "too-many-spaces", "collapse-and-trim"),
    ("Mixed -- Dashes", "mixed-dashes", "collapse-and-trim"),
    ("-Already-Hyphenated-", "already-hyphenated", "collapse-and-trim"),
    (" - odd - edges - ", "odd-edges", "collapse-and-trim"),
    ("Trailing Space ", "trailing-space", "collapse-and-trim"),
]

passed = 0
failures = []
for src, want, prop in CASES:
    try:
        got = slugify(src)
    except Exception as e:
        got = f"<raised {type(e).__name__}: {e}>"
    if got == want:
        passed += 1
    else:
        failures.append((src, want, got, prop))

print(f"slugify checker: {passed}/{len(CASES)} cases pass")
if failures:
    print("")
    print("failing cases:")
    for src, want, got, prop in failures:
        print(f"  [{prop}] slugify({src!r})")
        print(f"      expected: {want!r}")
        print(f"      actual:   {got!r}")
    props = sorted({f[3] for f in failures})
    print("")
    print("unmet properties: " + ", ".join(props))
    print("  lowercase-and-hyphenate: lowercase the text and join words with single hyphens")
    print("  collapse-and-trim: collapse any run of separators into ONE hyphen and")
    print("                     strip hyphens from both ends of the result")

score = round(passed * 100 / len(CASES))
print("")
print(f"score: {score}")
sys.exit(0 if score == 100 else 1)
