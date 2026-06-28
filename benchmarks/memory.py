#!/usr/bin/env python3
"""Peak memory (RSS) + CPU per tool, via BSD `/usr/bin/time -l` (macOS).

Measures the MAIN process of each tool: graff (tiny Zig binary), Claude Code
(Node), Codex (Rust). Each also spawns helpers (shell commands, code-intel) that
are NOT counted here. graff's RSS scales with how much code it reads into
context, so expect a range across tasks.

Prereqs: graff, claude, codex on PATH and authenticated; macOS.
Run:     python3 benchmarks/memory.py
"""
import subprocess, json, os, re
from tasks import TASKS
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def time_l(cmd, stdin=""):
    p = subprocess.run(["/usr/bin/time", "-l"] + cmd, input=stdin,
                       capture_output=True, text=True, timeout=360)
    rss = user = sys_ = None
    for l in p.stderr.splitlines():
        if "maximum resident set size" in l:
            try: rss = int(l.strip().split()[0])
            except Exception: pass
        m = re.search(r"([\d.]+)\s+real\s+([\d.]+)\s+user\s+([\d.]+)\s+sys", l)
        if m: _, user, sys_ = map(float, m.groups())
    return (rss or 0) / 1048576, (user or 0) + (sys_ or 0)

for task in TASKS:
    print(f"=== {task} ===")
    g_rss, g_cpu = time_l(["graff", "--model", "deepseek-v4-pro", "--json"],
                          json.dumps({"type": "user", "text": TASKS[task]}) + "\n")
    c_rss, c_cpu = time_l(["claude", "-p", TASKS[task], "--output-format", "json"])
    x_rss, x_cpu = time_l(["codex", "exec", "-s", "read-only", "--json", TASKS[task]])
    print(f"  graff (Zig)         RSS={g_rss:7.1f} MB   CPU={g_cpu:.1f}s")
    print(f"  Claude Code (Node)  RSS={c_rss:7.1f} MB   CPU={c_cpu:.1f}s")
    print(f"  Codex (Rust)        RSS={x_rss:7.1f} MB   CPU={x_cpu:.1f}s")
