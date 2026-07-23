#!/usr/bin/env python3
"""dgm_loop.py — the MINIMAL Darwin Gödel Machine loop on simple-harness.

The least things a DGM needs, and where each lives:

  1. genome          a system prompt
                     (auto-captured: kind:"prompt" records in the archive)
  2. archive+lineage variants, their fitness, and who-was-mutated-from-whom
                     (auto-captured: .graff/trajectories/*.jsonl; lineage via
                      score(parent=…))
  3. evaluate        grounded, Step 1: a held-out replay judge in a separate
                     process is the primary gradient (replay_eval below);
                     the LLM judge survives only as llm_tiebreak, which can
                     reorder passing variants but never admit a failing one
  4. modify          mutate a parent's prompt (one h.ask call)
  5. select          sigmoid(fitness − frontier) × 1/(1+children)
                     (~12 lines below, per arXiv:2505.22954 §parent selection)

Everything else — elites grids, OTEL, D1, queues — is observability and
distribution on top; the loop itself is this file.

Setup (once): python3 examples/replay_judge.py --pin   # then export the
printed GRAFF_EVAL_SET_FILE / GRAFF_EVAL_SET_HASH / GRAFF_REPLAY_JUDGE.

Usage:
    python3 examples/dgm_loop.py "summarize src/main.zig's Telemetry struct" 3
"""
import collections
import hashlib
import json
import math
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sdk", "py"))
from harness_sdk import Harness, prompt_fingerprint, verify_score  # noqa: E402

ARCHIVE_DIR = os.path.join(".graff", "trajectories")
LEGACY_ARCHIVE = "harness.trajectory.jsonl"


def archive_paths():
    """Current run-scoped archive files plus the pre-migration legacy file."""
    paths = []
    try:
        paths.extend(
            os.path.join(ARCHIVE_DIR, name)
            for name in sorted(os.listdir(ARCHIVE_DIR))
            if name.endswith(".jsonl")
        )
    except FileNotFoundError:
        pass
    if os.path.isfile(LEGACY_ARCHIVE):
        paths.append(LEGACY_ARCHIVE)
    return paths


def _score_key():
    """The HMAC key for verifying signed score rows, if GRAFF_SCORE_KEY_FILE
    is set (Step 0, fitness-channel integrity). None → signing off, accept
    rows as before. When set, load_archive rejects unsigned/forged scores so
    selection can't be poisoned by a hand-appended row."""
    path = os.environ.get("GRAFF_SCORE_KEY_FILE")
    if not path:
        return None
    try:
        with open(path, "rb") as f:
            key = f.read().strip()
        return key or None
    except OSError:
        return None
SEED = ("You are a focused agent. Do exactly what the task asks, verify your "
        "result before reporting, and report it plainly with evidence.")


def load_archive():
    """genomes: sha → prompt text; scores: sha → [values]; children: sha → n.

    When GRAFF_SCORE_KEY_FILE is set, score rows must carry a valid HMAC or
    they are dropped (and counted) — a forged trajectory score row can't
    poison fitness or manufacture lineage."""
    key = _score_key()
    genomes, scores, children = {}, collections.defaultdict(list), collections.Counter()
    seen_edges = set()
    rejected = 0
    for path in archive_paths():
        with open(path, encoding="utf-8") as archive:
            for ln in archive:
                o = json.loads(ln)
                if o.get("kind") == "prompt":
                    genomes[o["prompt_sha"]] = o["text"]
                elif o.get("kind") == "score":
                    if key is not None and not verify_score(key, o):
                        rejected += 1
                        continue
                    scores[o["prompt_sha"]].append(o["score"])
                    p = o.get("parent_sha")
                    if p and (p, o["prompt_sha"]) not in seen_edges:
                        seen_edges.add((p, o["prompt_sha"]))
                        children[p] += 1
    if rejected:
        print(f"  [archive] rejected {rejected} unsigned/forged score row(s)")
    return genomes, scores, children


def select_parent(genomes, scores, children):
    """DGM parent selection: sigmoid(score − frontier midpoint) × 1/(1+children)."""
    scored = [(sha, sum(v) / len(v)) for sha, v in scores.items() if sha in genomes]
    if not scored:
        return None
    mid = sum(sorted((s for _, s in scored), reverse=True)[:3]) / min(3, len(scored))
    weights = [(sha, (1 / (1 + math.exp(-10 * (s - mid)))) / (1 + children[sha]))
               for sha, s in scored]
    r = random.random() * sum(w for _, w in weights)
    for sha, w in weights:
        r -= w
        if r <= 0:
            return sha
    return weights[-1][0]


def replay_eval(child_prompt):
    """Step 1 primary gradient: run the genome through the held-out replay
    judge in a separate process (GRAFF_REPLAY_JUDGE — the pinned copy outside
    the editable tree; falls back to the in-tree copy with a warning).
    Returns the judge's JSON verdict, or None on ANY failure — the caller
    must treat None as fail-closed, not as a free pass."""
    judge_path = os.environ.get("GRAFF_REPLAY_JUDGE")
    if not judge_path:
        judge_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "replay_judge.py")
        print("  [judge] WARNING: GRAFF_REPLAY_JUDGE unset — using the "
              "in-tree judge copy (run replay_judge.py --pin)")
    try:
        r = subprocess.run([sys.executable, judge_path],
                           input=child_prompt, text=True,
                           stdout=subprocess.PIPE, timeout=1800)
        if r.returncode != 0:
            return None
        return json.loads(r.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return None


def llm_tiebreak(h, task, report):
    """The old LLM judge, demoted: a secondary gradient that only reorders
    variants that already pass the whole held-out suite."""
    v = h.ask("Rate from 0.0 to 1.0 how well this report fulfills the task. "
              "Reply with ONLY the number.\n"
              f"TASK: {task}\nREPORT: {report}")
    try:
        return max(0.0, min(1.0, float(v.strip().split()[0])))
    except (ValueError, IndexError):
        return 0.0


def judge(h, task, report, child):
    """Grounded evaluation (Step 1). Score bands make the invariant
    structural, not statistical:

      replay judge failed/missing  → 0.0                  (fail closed)
      pass_rate < 1.0              → 0.8 × pass_rate      (capped at 0.8)
      all held-out tasks pass      → 0.9 + 0.1 × efficiency

    A variant that fails any deterministic check can never reach the
    promotable band (≥ 0.9). Once correctness saturates (a capable model
    aces every deterministic task), the top band is decided by tool economy,
    not an LLM's vibe: efficiency = total / (total + tool_calls), so a genome
    that solves all N tasks with fewer tool calls ranks higher, and the 1.0
    ceiling demands zero wasted calls — genuinely hard to reach.
    Returns (score, eval_set_hash)."""
    res = replay_eval(child)
    if res is None:
        print("  [judge] replay judge unavailable or refused — fail closed, score 0.0")
        return 0.0, ""
    if res["pass_rate"] < 1.0:
        return 0.8 * res["pass_rate"], res["eval_set_hash"]
    total = res.get("total", 0)
    tcalls = res.get("total_tool_calls", 0)
    efficiency = total / (total + tcalls) if (total + tcalls) else 1.0
    print(f"  [judge] all {total} tasks pass — {tcalls} tool call(s), "
          f"efficiency {efficiency:.3f}, ${res.get('total_cost', 0):.4f}")
    return 0.9 + 0.1 * efficiency, res["eval_set_hash"]
def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    task = sys.argv[1]
    iters = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    h = Harness(yolo=True)
    for gen in range(iters):
        genomes, scores, children = load_archive()
        parent_sha = select_parent(genomes, scores, children)
        parent = genomes.get(parent_sha, SEED)
        # Modify: the meta step — the harness's own model mutates the genome.
        child = h.ask(
            "Rewrite this agent system prompt to perform better on tasks "
            f"like: {task}\nChange ONE meaningful behavior. Keep it under "
            f"120 words. Reply with ONLY the new prompt.\n---\n{parent}")
        # Spawn the child as a prompt variant; its run (incl. tool sequence)
        # lands in the archive automatically.
        report = h.ask(
            f'Call the subagent tool exactly once: description "dgm gen {gen}", '
            f'prompt {json.dumps(task)}, system_prompt {json.dumps(child)}. '
            "Then reply with the subagent report verbatim.")
        s, eval_hash = judge(h, task, report, child)
        # Evaluate write-back with the lineage edge + signed provenance:
        # who judged (judge_id), what artifact (report sha), on which pinned
        # eval set — all folded into the record's HMAC (Step 0).
        h.score(child, s, notes=f"gen {gen}", parent=parent_sha or SEED,
                judge_id="replay-v1",
                artifact_sha=hashlib.sha256(report.encode()).hexdigest()[:16],
                eval_set_hash=eval_hash)
        print(f"gen {gen}: parent={parent_sha or 'seed'} "
              f"child={prompt_fingerprint(child)} score={s:.2f}"
              f"{' [PASSING]' if s >= 0.9 else ' [failing]'}")
    h.close()
    print(f"archive: {ARCHIVE_DIR} — rerun to keep evolving; /trajectory to inspect")


if __name__ == "__main__":
    main()
