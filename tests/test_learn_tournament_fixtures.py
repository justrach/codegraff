#!/usr/bin/env python3
"""Deterministic regression tests for the tournament fixture barrier (#467).

The tournament E2E asserts on `mutator-attempts-{index}` counter files that the
fixture mutator used to write only *after* its four-way rendezvous loop. When a
peer launch lagged past the hardcoded rendezvous deadline, the mutator died at
its own assert before ever writing its counter, so the E2E saw an absent file.
These tests force that lag with a tiny rendezvous deadline and require the
counter to be recorded regardless of whether the rendezvous succeeds.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

from learn_tournament_fixtures import MUTATOR


def materialize_mutator(root: Path) -> Path:
    program = root / "tournament-mutator.py"
    program.write_text(MUTATOR)
    program.chmod(0o755)
    return program


def write_request(root: Path, index: int) -> tuple[Path, Path]:
    parent = root / f"parent-{index}.md"
    parent.write_text("parent genome\n")
    child = root / f"child-{index}.md"
    request = root / f"request-{index}.json"
    request.write_text(json.dumps({
        "schema": "codegraff.learn.mutation.request.v1",
        "trial_id": "0" * 64,
        "candidate_index": index,
        "seed": "seed",
        "parent": {"id": "a" * 64, "path": str(parent)},
        "child_path": str(child),
        "maximum_bytes": 4096,
        "instruction": "produce one variant",
    }))
    return request, child


def run_mutator(program: Path, barrier: Path, request: Path, response: Path, extra_env: dict) -> subprocess.CompletedProcess:
    env = {**os.environ, "TOURNAMENT_BARRIER": str(barrier), **extra_env}
    return subprocess.run(
        [sys.executable, str(program), "mutate", str(request), str(response)],
        env=env, capture_output=True, text=True,
    )


def test_mutator_records_attempt_when_rendezvous_times_out() -> None:
    # Peers never arrive: the rendezvous must fail (nonzero exit), but the
    # per-invocation attempt counter must still exist afterwards.
    with tempfile.TemporaryDirectory(prefix="tournament-fixture.") as tmp:
        root = Path(tmp)
        barrier = root / "barrier"
        barrier.mkdir()
        program = materialize_mutator(root)
        request, _ = write_request(root, 1)
        response = root / "response-1.json"
        result = run_mutator(
            program, root / "barrier", request, response,
            {"TOURNAMENT_BARRIER_DEADLINE": "0.05"},
        )
        assert result.returncode != 0, "rendezvous without peers must fail"
        attempts = barrier / "mutator-attempts-1"
        assert attempts.exists(), (
            f"attempt counter missing after invocation; stderr:\n{result.stderr}"
        )
        assert attempts.read_text() == "1"


def test_mutator_counts_each_invocation_across_retry() -> None:
    # Peers arrive late but within the tunable deadline: both invocations
    # complete, so a retried candidate counts exactly two attempts.
    with tempfile.TemporaryDirectory(prefix="tournament-fixture.") as tmp:
        root = Path(tmp)
        barrier = root / "barrier"
        barrier.mkdir()
        program = materialize_mutator(root)
        request, child = write_request(root, 1)
        response = root / "response-1.json"

        def arrive_late(index: int) -> None:
            (barrier / f"mutation-{index}").write_text("started")

        timers = [threading.Timer(0.2, arrive_late, args=(index,)) for index in (0, 2, 3)]
        for timer in timers:
            timer.start()
        try:
            first = run_mutator(
                program, barrier, request, response,
                {"TOURNAMENT_BARRIER_DEADLINE": "30"},
            )
        finally:
            for timer in timers:
                timer.cancel()
        assert first.returncode == 0, first.stderr
        assert child.read_text().startswith("parent genome")
        (barrier / "fail-mutator-1").write_text("fail like the e2e scenario")
        second = run_mutator(program, barrier, request, response, {})
        assert second.returncode != 0, "failure marker must fail the second attempt"
        assert (barrier / "mutator-attempts-1").read_text() == "2"


if __name__ == "__main__":
    test_mutator_records_attempt_when_rendezvous_times_out()
    test_mutator_counts_each_invocation_across_retry()
    print("ok")
