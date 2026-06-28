#!/usr/bin/env python3
"""One-shot turn latency, SAME model + endpoint: graff `--model codex` vs `codex exec`.

Both hit ChatGPT gpt-5.5 directly via ~/.codex/auth.json (NO codegraff gateway),
with reasoning effort matched to `high`, on a tool-free prompt (pure round-trip).
Each trial launches both CONCURRENTLY so they share the same network conditions,
then we print the distribution so you can tell a real gap from noise.

Caveat: this is one-shot / scripted mode (cold start each run). In a long
interactive session the startup cost amortizes and it becomes model-bound, so this
is an automation / `-p` / SDK speed result, not a blanket \"graff is faster\".

Prereqs: graff + codex on PATH; logged into Codex (`graff login codex`).
Run:     python3 benchmarks/latency.py [N]   (default N=8 trials)
"""
import subprocess, json, time, threading, statistics, sys

PROMPT = ("What is 17 times 23? Reply with only the number, nothing else. "
          "Do not use any tools or read any files.")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 8

def graff(res):
    req = '{"type":"set_effort","level":"high"}\n' + json.dumps({"type": "user", "text": PROMPT}) + "\n"
    t = time.time()
    subprocess.run(["graff", "--model", "codex", "--json"], input=req,
                   capture_output=True, text=True, timeout=180)
    res["g"] = time.time() - t

def codex(res):
    t = time.time()
    subprocess.run(["codex", "exec", "-s", "read-only", "--json",
                    "-c", "model_reasoning_effort=high", PROMPT], input="",
                   capture_output=True, text=True, timeout=180)
    res["c"] = time.time() - t

gt, ct = [], []
for i in range(N):
    res = {}
    tg = threading.Thread(target=graff, args=(res,))
    tx = threading.Thread(target=codex, args=(res,))
    tg.start(); tx.start(); tg.join(); tx.join()
    gt.append(res["g"]); ct.append(res["c"])
    print(f"trial {i+1}: graff={res['g']:5.1f}s  codex={res['c']:5.1f}s", flush=True)

gm, cm = statistics.mean(gt), statistics.mean(ct)
print(f"\ngraff --model codex: mean={gm:.2f}s sd={statistics.pstdev(gt):.2f} range={min(gt):.1f}-{max(gt):.1f}")
print(f"codex exec:          mean={cm:.2f}s sd={statistics.pstdev(ct):.2f} range={min(ct):.1f}-{max(ct):.1f}")
d = cm - gm
print(("graff faster by %.1fs (%.0f%%)" % (d, 100 * d / cm)) if d > 0
      else ("codex faster by %.1fs (%.0f%%)" % (-d, 100 * -d / gm)))
