#!/usr/bin/env python3
"""E2E + unit checks for the behavioral trace stream and its re-scorer.

Build first, then run:
    python3 scripts/test-behavior-trace.py zig-out/bin/graff

Covers, hermetically (network stays on 127.0.0.1 and is refused):
  1. A real one-shot session writes `.graff/behavior/<run_id>.jsonl` AND the
     legacy DGM trajectory `.graff/trajectories/<run_id>.jsonl` for the same
     run id. Regression for the exclusive-create collision that silently
     disabled local behavioral capture when both shared one directory.
  2. The produced stream passes the strict Phase 1 audit in score_run.py.
  3. score_run.py behavioral metrics and RHAE math on synthesized fixtures,
     including the replay_schema_harness.py conversion round trip.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
SCORE = SCRIPTS / "score_run.py"
REPLAY = SCRIPTS / "replay_schema_harness.py"


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, **kwargs)


def score(stream: Path, *args: str) -> dict:
    result = run([sys.executable, str(SCORE), *args, str(stream)])
    payload = json.loads(result.stdout)
    return {"exit": result.returncode, **payload}


def check_live_session(graff: Path, root: Path) -> None:
    workspace = root / "live"
    workspace.mkdir()
    env = os.environ.copy()
    env.update({
        "GRAFF_NO_TELEMETRY": "1",
        # Refused immediately: the discard port on localhost is closed.
        "GRAFF_LMSTUDIO_URL": "http://127.0.0.1:9",
    })
    result = run([str(graff), "--model", "lmstudio", "say hi"], cwd=workspace, env=env)
    assert result.returncode != 0, "dead-endpoint one-shot should fail"

    behavior_files = sorted((workspace / ".graff" / "behavior").glob("*.jsonl"))
    assert len(behavior_files) == 1, f"expected one behavioral file, got {behavior_files}"
    run_id = behavior_files[0].stem
    trajectory = workspace / ".graff" / "trajectories" / f"{run_id}.jsonl"
    assert trajectory.is_file(), "legacy DGM trajectory must coexist for the same run id"

    report = score(behavior_files[0])
    assert report["exit"] == 0 and report["ok"], f"strict audit failed: {report}"
    assert report["run_id"] == run_id
    assert report["complete"] and report["terminal_status"] == "error"
    assert report["counts"]["run_started"] == 1
    assert report["counts"]["turn_started"] >= 1
    first = json.loads(behavior_files[0].read_text().splitlines()[0])
    assert first["kind"] == "run_started" and first["schema"] == "codegraff.behavior.v1"
    print("live session: behavioral + trajectory streams coexist; strict audit ok")


def write_stream(path: Path, events: list[dict]) -> None:
    run_id = "feedbeeffeedbeef"
    with path.open("w", encoding="utf-8") as out:
        for seq, event in enumerate(events, start=1):
            record = {"seq": seq, "ts": 1770000000.0 + seq, "run_id": run_id,
                      "schema": "codegraff.behavior.v1", **event}
            out.write(json.dumps(record) + "\n")


def check_scorer(root: Path) -> None:
    # Behavioral metrics: 2 turns, 2 commitments, 1 mispredict, repair after.
    stream = root / "behavioral.jsonl"
    write_stream(stream, [
        {"kind": "run_started", "version": "test", "unix_ms": 1},
        {"kind": "turn_started", "turn": 1, "parent_turn": 0, "trajectory_node": 0},
        {"kind": "turn_committed", "turn": 1, "commitment_id": "c1",
         "action": {"kind": "edit"}, "expect": {"build": "passes"}, "reason": "try fix"},
        {"kind": "model_mispredicted", "turn": 1, "commitment_id": "c1",
         "predicted": {"build": "passes"}, "actual": {"build": "fails"}, "detail": "compile error"},
        {"kind": "turn_committed", "turn": 1, "commitment_id": "c2",
         "action": {"kind": "edit"}, "expect": {"build": "passes"}, "reason": "repair"},
        {"kind": "turn_started", "turn": 2, "parent_turn": 1, "trajectory_node": 0},
        {"kind": "run_finished", "status": "closed"},
    ])
    report = score(stream)
    assert report["ok"] and report["complete"]
    assert report["turns"] == 2 and report["commitments"] == 2 and report["mispredicts"] == 1
    assert report["mispredict_rate"] == 0.5
    assert report["commitment_coverage"] == 0.5
    assert report["mean_repair_gap_events"] == 1.0

    # Audit failures: seq gap, event after run_finished, dense-turn violation.
    gap = root / "gap.jsonl"
    write_stream(gap, [{"kind": "run_started", "version": "t", "unix_ms": 1},
                       {"kind": "run_finished", "status": "closed"}])
    lines = gap.read_text().splitlines()
    doctored = json.loads(lines[1]); doctored["seq"] = 5
    gap.write_text(lines[0] + "\n" + json.dumps(doctored) + "\n")
    assert score(gap)["exit"] == 1, "seq gap must fail the audit"

    # Truncated tail: incomplete final line is truncation, not corruption.
    trunc = root / "trunc.jsonl"
    write_stream(trunc, [{"kind": "run_started", "version": "t", "unix_ms": 1},
                         {"kind": "turn_started", "turn": 1, "parent_turn": 0, "trajectory_node": 0}])
    with trunc.open("a", encoding="utf-8") as out:
        out.write('{"kind":"run_fin')
    report = score(trunc)
    assert report["ok"] and report["truncated_tail"] and not report["complete"]

    # Declared local drops: a strict-profile seq gap is legal exactly when
    # run_finished accounts for it; anything else is truncation or tampering.
    def write_raw(path: Path, rows: list[tuple[int, dict]]) -> None:
        with path.open("w", encoding="utf-8") as out:
            for seq, event in rows:
                record = {"seq": seq, "ts": 1770000000.0 + seq, "run_id": "feedbeeffeedbeef",
                          "schema": "codegraff.behavior.v1", **event}
                out.write(json.dumps(record) + "\n")

    declared = root / "declared-gap.jsonl"
    write_raw(declared, [
        (1, {"kind": "run_started", "version": "t", "unix_ms": 1}),
        (2, {"kind": "turn_started", "turn": 1, "parent_turn": 0, "trajectory_node": 0}),
        (4, {"kind": "run_finished", "status": "closed", "local_dropped": 1}),
    ])
    report = score(declared)
    assert report["ok"] and report["seq_gaps"] == 1 and report["local_dropped"] == 1, report

    undeclared = root / "undeclared-gap.jsonl"
    write_raw(undeclared, [
        (1, {"kind": "run_started", "version": "t", "unix_ms": 1}),
        (4, {"kind": "run_finished", "status": "closed", "local_dropped": 0}),
    ])
    assert score(undeclared)["exit"] == 1, "gap without matching declaration must fail"

    # RHAE math on a synthetic replay: 2 levels, baselines 4 and 6, agent 2 and
    # 3 actions. Both levels cap at 115; the completion cap holds it to 100.
    arc = root / "arc.jsonl"
    write_stream(arc, [
        {"kind": "run_started", "game_id": "toy-1"},
        {"kind": "action_taken", "step_index": 0, "state": "NOT_FINISHED"},
        {"kind": "action_taken", "step_index": 1, "state": "NOT_FINISHED", "level_up": True},
        {"kind": "action_taken", "step_index": 2, "state": "NOT_FINISHED"},
        {"kind": "action_taken", "step_index": 3, "state": "NOT_FINISHED"},
        {"kind": "action_taken", "step_index": 4, "state": "WIN", "level_up": True},
        {"kind": "run_finished", "state": "WIN", "actions": 5},
    ])
    baseline = root / "baseline.csv"
    baseline.write_text("game,game_id,n_levels,level1,level2\ntoy,toy-1,2,4,6\n")
    report = score(arc, "--profile", "replay", "--baseline", str(baseline), "--game", "toy-1")
    assert report["ok"], report
    assert report["completed_level_actions"] == [2, 3]
    assert report["rhae"]["per_level_scores"] == [115.0, 115.0]
    assert report["rhae"]["score"] == 100.0

    # Partial run: only level 1 completed. raw = 115*1/3, cap = 1/3*100.
    partial = root / "partial.jsonl"
    write_stream(partial, [
        {"kind": "run_started", "game_id": "toy-1"},
        {"kind": "action_taken", "step_index": 0, "state": "NOT_FINISHED", "level_up": True},
        {"kind": "action_taken", "step_index": 1, "state": "NOT_FINISHED"},
        {"kind": "run_finished", "state": "NOT_FINISHED", "actions": 2},
    ])
    report = score(partial, "--profile", "replay", "--baseline", str(baseline), "--game", "toy-1")
    assert report["ok"], report
    assert report["completed_level_actions"] == [1]
    assert report["rhae"]["score"] == round(min(115.0 * 1 / 3, 1 / 3 * 100.0), 2)

    # #255 opt-in rich capture (GRAFF_BEHAVIOR_TRACE=full): tool_started/
    # tool_finished pair by call_id, action_taken is the state-mutation
    # subset of finished tool calls, text_delta is completed assistant text.
    rich = root / "rich.jsonl"
    write_stream(rich, [
        {"kind": "run_started", "version": "test", "unix_ms": 1},
        {"kind": "turn_started", "turn": 1, "parent_turn": 0, "trajectory_node": 0},
        {"kind": "text_delta", "turn": 1, "text": "on it", "text_truncated": False},
        {"kind": "tool_started", "turn": 1, "call_id": 1, "name": "edit_file",
         "args": {"path": "a.zig"}, "args_truncated": False},
        {"kind": "tool_finished", "turn": 1, "call_id": 1, "name": "edit_file",
         "ms": 5, "is_error": False, "result_bytes": 40},
        {"kind": "action_taken", "turn": 1, "call_id": 1, "name": "edit_file", "is_error": False},
        {"kind": "run_finished", "status": "closed"},
    ])
    report = score(rich)
    assert report["ok"] and report["complete"], report
    assert report["tool_calls"] == 1 and report["tool_errors"] == 0
    assert report["text_deltas"] == 1
    assert report["actions"] == 1

    # A tool_finished with no matching tool_started is a pairing violation,
    # not a warning — it must fail the strict audit.
    mismatch = root / "rich-mismatch.jsonl"
    write_stream(mismatch, [
        {"kind": "run_started", "version": "test", "unix_ms": 1},
        {"kind": "turn_started", "turn": 1, "parent_turn": 0, "trajectory_node": 0},
        {"kind": "tool_finished", "turn": 1, "call_id": 1, "name": "edit_file",
         "ms": 5, "is_error": False, "result_bytes": 40},
        {"kind": "run_finished", "status": "closed"},
    ])
    assert score(mismatch)["exit"] == 1, "tool_finished without tool_started must fail the audit"
    print("scorer: behavioral metrics, audit failures, truncation, RHAE math, rich-kind pairing ok")


def check_replay_round_trip(root: Path) -> None:
    source = root / "harness-events.jsonl"
    events = [
        {"kind": "run_started", "seq": 10, "ts": 5.0, "game_id": "toy-1"},
        {"kind": "turn_started", "seq": 11, "ts": 6.0, "turn": 1, "grid": [[0]]},
        {"kind": "turn_committed", "seq": 12, "ts": 7.0, "turn": 1, "plan": ["up"], "reason": "explore"},
        {"kind": "action_taken", "seq": 13, "ts": 8.0, "turn": 1, "step_index": 0,
         "state": "WIN", "level_up": True},
        {"kind": "run_finished", "seq": 14, "ts": 9.0, "state": "WIN", "actions": 1},
    ]
    with source.open("w", encoding="utf-8") as out:
        for event in events:
            out.write(json.dumps(event) + "\n")
    converted = root / "converted.jsonl"
    result = run([sys.executable, str(REPLAY), str(source), str(converted), "--run-id", "abc123"])
    assert result.returncode == 0, result.stderr
    summary = json.loads(result.stdout)
    assert summary == {"run_id": "abc123", "events": 5,
                       "kinds": {"action_taken": 1, "run_finished": 1, "run_started": 1,
                                 "turn_committed": 1, "turn_started": 1}}
    lines = [json.loads(l) for l in converted.read_text().splitlines()]
    assert [l["seq"] for l in lines] == [1, 2, 3, 4, 5], "seq must be renumbered contiguously"
    assert all(l["run_id"] == "abc123" and l["schema"] == "codegraff.behavior.v1" for l in lines)
    assert lines[2]["plan"] == ["up"] and lines[1]["grid"] == [[0]], "task fields must pass through"
    baseline = root / "baseline.csv"
    report = score(converted, "--profile", "replay", "--baseline", str(baseline), "--game", "toy-1")
    assert report["ok"] and report["rhae"]["score"] == round(min(115.0 * 1 / 3, 1 / 3 * 100.0), 2)
    print("replay: conversion round trip + re-score ok")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <graff-binary>", file=sys.stderr)
        return 2
    graff = Path(sys.argv[1]).resolve()
    if not graff.is_file():
        print(f"graff binary not found: {graff}", file=sys.stderr)
        return 2
    root = Path(tempfile.mkdtemp(prefix="codegraff-behavior-e2e."))
    try:
        check_live_session(graff, root)
        check_scorer(root)
        check_replay_round_trip(root)
    except Exception:
        print(f"behavior E2E failed; fixture preserved at {root}", file=sys.stderr)
        raise
    shutil.rmtree(root)
    print("behavior E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
