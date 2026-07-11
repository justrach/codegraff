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
"""
import subprocess, json, os, sys

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

N = int(sys.argv[1]) if len(sys.argv) > 1 else 16
GRAFF = sys.argv[2] if len(sys.argv) > 2 else "graff"

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
    env = {**os.environ, "GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off"}
    p = subprocess.Popen([GRAFF, "--model", "deepseek-v4-pro", "--json"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, env=env, bufsize=1)
    samples = []
    try:
        # Queue all turns up front (small JSON lines fit the pipe buffer), keep
        # stdin open so the child stays alive for the final RSS sample, then read
        # + sample at each turn boundary. graff processes them sequentially.
        for i in range(N):
            p.stdin.write(json.dumps({"type": "user", "text": PROMPTS[i % len(PROMPTS)]}) + "\n")
        p.stdin.flush()
        p.stdin.close()  # EOF after the queued turns so graff drains them all then exits
        done = 0
        while done < N:
            line = p.stdout.readline()
            if not line:
                raise RuntimeError("graff exited early after %d/%d turns" % (done, N))
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("type") == "error":
                print("  (error: %s)" % ev.get("message"))
            if ev.get("type") == "turn" and ev.get("complete"):
                done += 1
                r = rss_mb(p.pid)
                samples.append((done, r))
                print("  turn %2d: RSS = %7.1f MB" % (done, r))
    finally:
        try:
            p.stdin.close(); p.terminate(); p.wait(timeout=5)
        except Exception:
            p.kill()

    tail = samples[2:] if len(samples) > 4 else samples  # drop warmup
    if len(tail) >= 2:
        xs = [x for x, _ in tail]
        ys = [y for _, y in tail]
        n = len(tail)
        mx, my = sum(xs) / n, sum(ys) / n
        den = sum((x - mx) ** 2 for x in xs) or 1.0
        slope = sum((x - mx) * (y - my) for x, y in tail) / den
        verdict = "FLAT — no per-turn leak" if abs(slope) < 0.1 else "GROWING — leak present"
        print("\nRSS growth over turns %d..%d: %+.3f MB/turn  (%s)"
              % (xs[0], xs[-1], slope, verdict))
        print("first-tail %.1f MB -> peak %.1f MB" % (ys[0], max(ys)))


if __name__ == "__main__":
    main()
