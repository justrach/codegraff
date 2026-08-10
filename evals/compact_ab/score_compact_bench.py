#!/usr/bin/env python3
"""Score compaction-benchmark runs: correctness + compaction counts + cost/time."""
import json, os, re, sys, glob

B = "/tmp/compact_bench"
qs = json.load(open(f"{B}/questions.json"))

def score_run(d):
    out = {"run": os.path.basename(d.rstrip("/"))}
    log = open(os.path.join(d, "out.log"), errors="replace").read()
    out["server_compacts"] = log.count("[server compacted context")
    out["client_compacts"] = log.count("[history compacted to") + log.count("[compacting ~")
    out["done"] = "DONE" in log
    wall = os.path.join(d, "wall_seconds")
    out["wall"] = open(wall).read().strip() + "s" if os.path.exists(wall) else "?"
    # answers
    path = os.path.join(d, "answer.md")
    answers = {}
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            m = re.match(r"Q(\d+):\s*(.+?)\s*$", line)
            if m:
                answers[int(m.group(1))] = m.group(2)
    correct, wrong = 0, []
    for q in qs:
        got = answers.get(q["q"])
        exp = q["expect"]
        ok = got is not None and (got == exp or got.strip('"') == exp.strip('"'))
        if ok:
            correct += 1
        else:
            wrong.append(f'Q{q["q"]}({q["file"]}): got {got!r} want {exp!r}')
    out["score"] = f"{correct}/10"
    out["wrong"] = wrong
    # token/time metrics from the session jsonl trace if present
    traces = glob.glob(os.path.join(d, ".graff/traces/*.jsonl"))
    if traces:
        reqs = toks = 0
        for line in open(traces[0], errors="replace"):
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("ev") == "api":
                reqs += 1
                toks += ev.get("context_tokens", 0) or 0
        out["api_calls"] = reqs
        out["sum_context_tokens"] = toks
    return out

runs = sorted(glob.glob(f"{B}/runs/*/"), key=os.path.getmtime)
if len(sys.argv) > 1:
    runs = [d for d in runs if any(a in d for a in sys.argv[1:])]
print(f"{'run':<10} {'score':<6} {'srvCmp':<6} {'cliCmp':<6} {'done':<5} {'wall':<6} {'api':<4} {'sumCtxTok':<10}")
for d in runs:
    r = score_run(d)
    print(f"{r['run']:<10} {r['score']:<6} {r['server_compacts']:<6} {r['client_compacts']:<6} "
          f"{str(r['done']):<5} {r['wall']:<6} {r.get('api_calls','?'):<4} {r.get('sum_context_tokens','?'):<10}")
    for w in r["wrong"]:
        print("   ", w)
