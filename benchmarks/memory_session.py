#!/usr/bin/env python3
"""Session RSS-vs-turn: does a long-lived graff conversation leak memory?

`memory.py` measures ONE-SHOT peak RSS, which is structurally blind to per-turn
growth — a one-shot reads one line and exits before accumulation matters. This
drives a SINGLE persistent `graff --json` child through N turns (stdin kept
open), samples its RSS at each turn boundary, and prints the RSS-vs-turn curve
plus a least-squares MB/turn slope over the post-warmup tail.

Flat-after-warmup = fine. A positive slope is the #124 leak (the root Agent's
session arena never resets, so per-SSE-event parse garbage accumulates for the
life of the process) — now with a number to confirm or refute a fix.

Run:  CODEGRAFF_API_KEY=... python3 benchmarks/memory_session.py [N] [graff-path]
      N defaults to 16; graff-path defaults to `graff` on PATH.
      GRAFF_BENCH_MODEL selects the model (default: deepseek-v4-pro).
"""
import subprocess, json, os, sys

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

N = int(sys.argv[1]) if len(sys.argv) > 1 else 16
GRAFF = sys.argv[2] if len(sys.argv) > 2 else "graff"
MODEL = os.environ.get("GRAFF_BENCH_MODEL", "deepseek-v4-pro")
SLOPE_LIMIT_MB = 0.1

# Short prompts that each stream a paragraph — many SSE events per turn (the
# parse-garbage axis #124 is about) without slow multi-tool work, so the RSS
# curve has plenty of samples. Swap in benchmarks/tasks.py for tool-heavy turns.
PROMPTS = [
    "In one paragraph, explain what a mutex is.",
    "Name five programming languages and one strength of each.",
    "Write a haiku about garbage collection.",
    "In one paragraph, explain TCP vs UDP.",
    "List four sorting algorithms with their average time complexity.",
    "In one paragraph, explain what an arena allocator is.",
]


def rss_mb(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                             capture_output=True, text=True)
        return int(out.stdout.strip()) / 1024.0
    except Exception:
        return 0.0


def main():
    if N < 2:
        raise SystemExit("N must be at least 2")
    env = {**os.environ, "GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off",
           "GRAFF_MEM_DEBUG": "1"}
    p = subprocess.Popen([GRAFF, "--model", MODEL, "--json"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, env=env, bufsize=1)
    samples = []
    try:
        # Drive one turn at a time and keep stdin open through every sample.
        # Closing it up front races the final sample against process exit, which
        # can produce a bogus 0 MB reading and a wildly negative slope.
        for i in range(N):
            p.stdin.write(json.dumps({"type": "user", "text": PROMPTS[i % len(PROMPTS)]}) + "\n")
            p.stdin.flush()
            arena = None
            while True:
                line = p.stdout.readline()
                if not line:
                    raise RuntimeError("graff exited early after %d/%d turns (exit %s)" %
                                       (i, N, p.poll()))
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if ev.get("type") == "error":
                    raise RuntimeError("turn %d failed: %s" % (i + 1, ev.get("message")))
                if ev.get("type") == "mem":
                    arena = (ev.get("session_arena_kb", 0), ev.get("scratch_arena_kb", 0))
                if ev.get("type") == "turn" and ev.get("complete"):
                    r = rss_mb(p.pid)
                    if r <= 0:
                        raise RuntimeError("could not sample RSS for live graff process %d" % p.pid)
                    samples.append((i + 1, r))
                    detail = ("  arenas: session=%d KB scratch=%d KB" % arena) if arena else ""
                    print("  turn %2d: RSS = %7.1f MB%s" % (i + 1, r, detail))
                    break
    finally:
        if p.stdin and not p.stdin.closed:
            p.stdin.close()
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    tail = samples[2:] if len(samples) > 4 else samples  # drop warmup
    if len(tail) >= 2:
        xs = [x for x, _ in tail]
        ys = [y for _, y in tail]
        n = len(tail)
        mx, my = sum(xs) / n, sum(ys) / n
        den = sum((x - mx) ** 2 for x in xs) or 1.0
        slope = sum((x - mx) * (y - my) for x, y in tail) / den
        if slope > SLOPE_LIMIT_MB:
            verdict = "GROWING — investigate retained memory"
        elif slope < -SLOPE_LIMIT_MB:
            verdict = "SHRINKING — no per-turn leak"
        else:
            verdict = "FLAT — no per-turn leak"
        print("\nRSS growth over turns %d..%d: %+.3f MB/turn  (%s)"
              % (xs[0], xs[-1], slope, verdict))
        print("first-tail %.1f MB -> peak %.1f MB" % (ys[0], max(ys)))


if __name__ == "__main__":
    main()
