#!/usr/bin/env python3
"""Long-horizon memory A/B: graff as shipped vs graff + OptMem.

The question: after several real compactions, can the agent still produce facts
it saw ONCE, early, that no longer exist on disk?

Arm `base` is v0.0.242 as shipped, which already carries the append-only
transcript (#441), pre-compaction notes-to-self (#391) and the post-compaction
durable-state note (#411). So this is not "OptMem vs nothing" — it is "does
OptMem add anything on top of what we just shipped", which is the actual
decision.
"""
import json, os, pathlib, random, re, shutil, string, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent
FIX = ROOT / "fixture"
RUNS = ROOT / "runs"
MEMO = pathlib.Path(os.environ.get("LH_MEMO_BIN", ""))  # optional comparison arm; not vendored

GRAFF = os.environ.get("GRAFF_BIN", "/Users/blackfloofie/codegraff/zig-out/bin/graff")
MODEL = os.environ.get("GRAFF_EVAL_MODEL", "gpt-5.6-sol")
STEPS = int(os.environ.get("LH_STEPS", "12"))
FILLER = int(os.environ.get("LH_FILLER", "26"))     # lines/step, under the 4096B handle threshold
COMPACT_PCT = os.environ.get("LH_COMPACT_PCT", "4")  # % of the window at which compaction fires.
# GRAFF_CONTEXT is NOT the knob here: it only applies to models whose window
# graff cannot look up, and gpt-5.6-sol has a known 270k one, so it is ignored.
# Forcing a low compaction PERCENT is what makes a short run cross the boundary
# several times, which is the whole point of the fixture.
TIMEOUT = int(os.environ.get("LH_TIMEOUT", "900"))

RECALL_TASK = (
    "A previous session in this same directory worked through probe.py and saw "
    "{n} one-time TOKEN values. That session is over and its conversation is "
    "gone. The tokens were erased from probe.py's state when they were printed, "
    "so re-running it will not reveal them.\n\n"
    "Recover as many of those tokens as you can from whatever durable record "
    "the previous session left behind, and report them. Reply with EXACTLY one "
    "line per token you recover and nothing else, labelled by the step number "
    "that printed it:\nTOKEN-<step>=<value>\n"
    "If you genuinely cannot recover a token, omit its line rather than guessing."
)

TASK = (
    "Work through probe.py one step at a time, starting with "
    "`python3 probe.py step {start}`. Each step prints a TOKEN and then tells "
    "you which step to run NEXT — you cannot know the order in advance, so run "
    "exactly one step per turn and follow the chain until a step says there is "
    "no next one. Each TOKEN is ERASED from disk the moment it is printed; it "
    "is never printed again, so you cannot go back for it.\n\n"
    "IMPORTANT: a LATER, SEPARATE session — with none of this conversation "
    "available — will be asked to recover these tokens. Whatever durable record "
    "you rely on, make sure they survive this session ending.\n\n"
    "When the chain ends, reply with EXACTLY one line per token and nothing "
    "else. Label each token with the STEP NUMBER that printed it — the N in "
    "that step's `TOKEN-N:` line — NOT the order you visited them in. Sort by "
    "step number:\n"
    "TOKEN-1=<value>\nTOKEN-2=<value>\n...\nTOKEN-{n}=<value>"
)


def make_tokens(rng):
    al = string.ascii_uppercase + string.digits
    ids = [str(i) for i in range(1, STEPS + 1)]
    order = ids[:]
    rng.shuffle(order)          # traversal order is scrambled so it cannot be guessed
    toks = {i: "".join(rng.choice(al) for _ in range(8)) for i in ids}
    return toks, order


def setup(dest, arm, tokens):
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    shutil.copy2(FIX / "probe.py", dest / "probe.py")
    toks, order = tokens
    nxt = {order[i]: (order[i + 1] if i + 1 < len(order) else None) for i in range(len(order))}
    (dest / ".state.json").write_text(json.dumps({
        "filler_lines": FILLER,
        "start": order[0],
        "steps": {k: {"token": v, "consumed": False, "next": nxt[k]} for k, v in toks.items()},
    }))

    home = dest / "_home"
    home.mkdir()
    # graff resolves credentials out of HOME (~/.codex/auth.json and friends),
    # and OptMem keys its store on HOME too. So the per-run HOME symlinks the
    # credential dirs back to the real one — auth keeps working while .optmem
    # stays isolated per run. Both arms get the identical shape, so the only
    # difference between them is the memory instructions.
    real = pathlib.Path(os.environ.get("REAL_HOME", os.path.expanduser("~")))
    for cred in (".codex", ".codegraff", ".config"):
        src = real / cred
        if src.exists():
            try:
                (home / cred).symlink_to(src)
            except OSError:
                pass
    agents = ["# Project", "", "Follow the task exactly. Be concise."]

    if arm == "optmem":
        if not MEMO.exists():
            sys.exit("the optmem arm needs LH_MEMO_BIN pointing at a `memo` "
                     "binary; see RESULTS-2026-08-06-optmem.md for why this "
                     "arm exists and what it measured")
        shutil.copy2(MEMO, home / "memo")
        os.chmod(home / "memo", 0o755)
        init = subprocess.run([str(home / "memo"), "init"], capture_output=True,
                              text=True, env={**os.environ, "HOME": str(home)})
        # Use OptMem's OWN prescribed instructions, not a paraphrase of them.
        block = init.stdout.split("Paste this at the top", 1)
        agents += ["", (block[1].split("\n", 1)[1] if len(block) > 1 else init.stdout).strip()]
    (dest / "AGENTS.md").write_text("\n".join(agents) + "\n")
    return home


def graff_cmd(task, calls="60"):
    return [GRAFF, "--model", MODEL, "--no-telemetry", "--new", "--yolo", "-p",
            "--max-model-calls", calls, task]


def one_run(arm, idx, tokens):
    dest = RUNS / arm / str(idx)
    home = setup(dest, arm, tokens)
    env = {**os.environ, "HOME": str(home), "GRAFF_NO_TELEMETRY": "1",
           "GRAFF_COMPACT_PCT": COMPACT_PCT}
    start = json.loads((dest / ".state.json").read_text())["start"]
    cmd = graff_cmd(TASK.format(n=STEPS, start=start))
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=dest, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
        out, err, rc, killed = p.stdout, p.stderr, p.returncode, False
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = (e.stderr or b"").decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        rc, killed = -1, True
    wall = time.time() - t0

    (dest / "_stdout.txt").write_text(out)
    (dest / "_stderr.txt").write_text(err)

    # ── phase 2: a cold session. Same cwd, no shared history. ───────────────
    p2out = p2err = ""
    if not killed:
        try:
            p2 = subprocess.run(graff_cmd(RECALL_TASK.format(n=STEPS), "40"),
                                cwd=dest, capture_output=True, text=True,
                                timeout=TIMEOUT, env=env)
            p2out, p2err = p2.stdout, p2.stderr
        except subprocess.TimeoutExpired:
            p2out, p2err = "", "(phase 2 timed out)"
    (dest / "_p2_stdout.txt").write_text(p2out)
    (dest / "_p2_stderr.txt").write_text(p2err)

    # Phase 1 recall is trivial (the tokens are in-context), so it is recorded
    # only as a sanity check that the chain completed. The REAL score is phase
    # 2: a cold session that must recover them from a durable store.
    toks = tokens[0]
    pat = r"TOKEN-(\d+)\s*=\s*([A-Z0-9]{8})"
    got1 = dict(re.findall(pat, out))
    p1_correct = sum(1 for k, v in toks.items() if got1.get(k) == v)

    got2 = dict(re.findall(pat, p2out))
    correct = sum(1 for k, v in toks.items() if got2.get(k) == v)
    # Anywhere-in-output credit separates "forgot it" from "mislabelled it".
    loose = sum(1 for v in toks.values() if v in p2out)
    # An agent that INVENTS plausible tokens is worse than one that admits it
    # cannot recover them, and a hits-only score would hide that entirely.
    wrong = sum(1 for k, v in got2.items() if toks.get(k) and toks[k] != v)

    u = re.search(r"\[usage\]\s+(\d+)\s+api call\(s\)\s+.\s+(\d+)\s+in\s+\((\d+)\s+cached\)\s*\+\s*(\d+)\s+out", err)
    rec = {
        "arm": arm, "run": idx, "rc": rc, "timed_out": killed, "wall_s": round(wall, 1),
        "p1_correct": p1_correct, "correct": correct, "loose": loose,
        "fabricated": wrong, "of": STEPS,
        "compactions": err.count("[history compacted"),
        "api_calls": int(u.group(1)) if u else None,
        "input_tokens": int(u.group(2)) if u else None,
        "output_tokens": int(u.group(4)) if u else None,
        "memo_notes": (err + out).count("memo note"),
        "memo_log_lines": len([l for l in (home / ".optmem/memory/LOG.txt").read_text().splitlines() if l.strip()]) if (home / ".optmem/memory/LOG.txt").exists() else 0,
    }
    (dest / "meta.json").write_text(json.dumps(rec, indent=2))
    return rec


def main():
    arms = sys.argv[1].split(",") if len(sys.argv) > 1 else ["base", "optmem"]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    RUNS.mkdir(exist_ok=True)
    seed = int(os.environ.get("LH_SEED", "20260806"))
    allrecs = []
    for i in range(1, n + 1):
        # Same tokens across arms within a run index: a paired comparison.
        tokens = make_tokens(random.Random(seed + i))
        for arm in arms:
            r = one_run(arm, i, tokens)
            allrecs.append(r)
            print(f"{arm:8s} #{i}  phase1={r['p1_correct']}/{r['of']}  "
                  f"COLD-RECALL={r['correct']}/{r['of']} exact ({r['loose']} anywhere, "
                  f"{r['fabricated']} wrong)  memo_notes={r['memo_notes']} "
                  f"log_lines={r['memo_log_lines']}  compactions={r['compactions']}  "
                  f"in={r['input_tokens']}  {r['wall_s']}s")
            sys.stdout.flush()
    (ROOT / "results.json").write_text(json.dumps(allrecs, indent=2))
    print(f"\nwrote {ROOT/'results.json'}")


if __name__ == "__main__":
    main()
