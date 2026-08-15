#!/usr/bin/env python3
"""Characterize the Lean corpus: proofs vs in-Lean evals.

A *proof* is a `theorem` (holds for every matching state).
An *example* is a closed cell (`native_decide`) — an eval sitting in Lean.
`sorry` is a fake proof. Growing right means theorems go up on the
∀-shaped kernels; examples going up alone is just a bigger eval suite.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "lean-proofs" / "Graff"


def main() -> int:
    tot_th = tot_ex = tot_so = 0
    print(f"{'file':<20} {'thm':>4} {'ex':>4} {'sorry':>5}  kind")
    for p in sorted(ROOT.glob("*.lean")):
        t = p.read_text()
        th = len(re.findall(r"^theorem ", t, re.M))
        ex = len(re.findall(r"^example ", t, re.M))
        so = len(re.findall(r"\bsorry\b", t))
        tot_th += th
        tot_ex += ex
        tot_so += so
        n = th + ex
        kind = "empty" if n == 0 else ("proof-heavy" if th >= ex else ("eval-in-lean" if th == 0 else "mixed"))
        print(f"{p.name:<20} {th:4d} {ex:4d} {so:5d}  {kind}")
    n = tot_th + tot_ex
    ratio = (tot_th / n) if n else 0
    print()
    print(f"claims {n}  theorems {tot_th}  examples {tot_ex}  sorry {tot_so}")
    print(f"proof_ratio {ratio:.2f}   (1.00 = every claim is ∀, 0.00 = Lean is only a test runner)")
    print("grade " + ("FAIL sorry" if tot_so else ("proof-led" if ratio >= 0.3 else ("mixed" if tot_th else "eval-in-lean"))))
    print("cell counts come from `lake exe graff-spec-report` (Lean), not this script")
    return 0 if tot_so == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
