#!/usr/bin/env python3
"""Inventory of the conformance corpus — is the triangle still complete?

Growing right means every live kernel still has Lean + ref + fixture + Zig,
cell counts never fall below the floor, and the Zig file names a real impl.
This is the thing a CI job or a human can prod without running lake.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
MANIFEST = ROOT / "manifest.json"


def _exists(rel: str) -> bool:
    return (REPO / rel).is_file()


def _count(fixture: Path, key) -> int:
    data = json.loads(fixture.read_text())
    if isinstance(key, list):
        return sum(len(data.get(k, [])) for k in key)
    return len(data.get(key, []))


def inventory() -> dict:
    man = json.loads(MANIFEST.read_text())
    kernels = []
    ok = True
    for k in man["kernels"]:
        fixture = REPO / k["fixture"]
        cells = _count(fixture, k["cells_key"]) if fixture.is_file() else 0
        floor = int(k["cells_floor"])
        triangle = {
            "lean": _exists(k["lean"]),
            "ref": _exists(k["ref"]),
            "fixture": fixture.is_file(),
            "zig": _exists(k["zig"]),
        }
        complete = all(triangle.values())
        above = cells >= floor
        row_ok = complete and above
        ok = ok and row_ok
        kernels.append(
            {
                "id": k["id"],
                "impl": k["impl"],
                "cells": cells,
                "cells_floor": floor,
                "triangle": triangle,
                "complete": complete,
                "ok": row_ok,
            }
        )
    lake = shutil.which("lake")
    lean = shutil.which("lean")
    lean_ver = None
    if lean:
        r = subprocess.run([lean, "--version"], capture_output=True, text=True)
        lean_ver = (r.stdout or r.stderr).strip().splitlines()[0] if r.returncode == 0 else None
    return {
        "ok": ok,
        "schema": man["schema"],
        "kernels": kernels,
        "cells_total": sum(k["cells"] for k in kernels),
        "triangles": sum(1 for k in kernels if k["complete"]),
        "triangles_want": len(kernels),
        "lean": {"lake": lake, "lean": lean, "version": lean_ver},
    }


def render(inv: dict) -> str:
    lines = [
        f"spec  triangles {inv['triangles']}/{inv['triangles_want']}  cells {inv['cells_total']}  "
        + ("ok" if inv["ok"] else "FAIL"),
    ]
    ver = inv["lean"]["version"] or "lake/lean not on PATH"
    lines.append(f"lean  {ver}")
    for k in inv["kernels"]:
        bits = "".join("L" if k["triangle"]["lean"] else ".")
        bits += "R" if k["triangle"]["ref"] else "."
        bits += "F" if k["triangle"]["fixture"] else "."
        bits += "Z" if k["triangle"]["zig"] else "."
        mark = "ok " if k["ok"] else "BAD"
        lines.append(
            f"  {mark}  {k['id']:<14} {bits}  {k['cells']:>4} cells (floor {k['cells_floor']})  {k['impl']}"
        )
    return "\n".join(lines)


def main() -> int:
    as_json = "--json" in sys.argv
    inv = inventory()
    if as_json:
        print(json.dumps(inv, indent=2))
    else:
        print(render(inv))
    return 0 if inv["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
