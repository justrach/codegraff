#!/usr/bin/env python3
"""Run the shared offline publication/constraint cases; no public writes.

These prove policy delivery and deterministic local payload/ledger behavior,
not a live model's privacy judgment.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
command = [sys.executable, str(ROOT / "scripts/eval-tier2.py")]
if len(sys.argv) > 1:
    command += ["--graff", str(pathlib.Path(sys.argv[1]).resolve())]
for case in (
    "publication-root-local-capture-739",
    "publication-child-local-capture-739",
    "publication-workflow-local-capture-739",
    "publication-custom-override-739",
    "constraint-same-turn-738",
):
    command += ["--only", case]
raise SystemExit(subprocess.call(command))
