#!/usr/bin/env python3
"""Hermetic cold-start benchmark for graff; see docs/harness-latency.md.

Times four ready points from process spawn, with no network and no credentials:
  a_version / a_help   `--version` / `--help` exit (wall)
  b_repl_ready         line REPL reaches its loop (stdin=/dev/null; first
                       GRAFF_SHUTDOWN_DEBUG `final-save` stamp on stderr)
  c_first_request      `-p hi --model lmstudio`: first POST at the loopback mock
  d_acp_initialize     `graff acp`: the `initialize` response line on stdout,
                       "handshake answered" (graff may answer it before the
                       session exists; `_nokey` variant: no credential, pre-auth)
  d_acp_session_usable `graff acp` with `initialize` and `session/new` written
                       at spawn: the `session/new` response, "ACP session usable"
plus a floor (/usr/bin/true and a compiled C hello) timed the same way.

The mock sits on the lmstudio provider's fixed port 127.0.0.1:1234. Each
sample gets its own LMSTUDIO_API_KEY token, so a POST from another client on
that port is recognised by its bearer and the sample is retried.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_startup_lib import (  # noqa: E402
    LIVE, BenchError, Fixture, check_budgets, compare, cpu_name, parse_spawns, print_summary,
    reap_group, run_stream, run_wall, start_mock, stats, tail,
)

SCHEMA = 1
INIT = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}\n'
FOREIGN_RETRIES = 5  # samples redone after a stray client hit the shared mock port
BOOT_LINE = re.compile(r"^\[boot \+(\d+)ms, phase (\d+)ms\] (.+)$")
# Safety vars are fixed; --env may not override them.
PROTECTED = {"HOME", "PATH", "GRAFF_NO_TELEMETRY", "GRAFF_NO_UPDATE_CHECK", "GRAFF_AUTO_ISOLATE",
             "LMSTUDIO_API_KEY"}
# Git subcommands that reach a remote or mean auto-isolation fired. Any of them fails the run.
FORBIDDEN_GIT = ("fetch", "pull", "push", "clone", "ls-remote", "remote update", "worktree add")


# ---------------------------------------------------------------- points

def acp_response(want_id):
    def ready(tag, line):
        if tag != "out":
            return False
        try:
            message = json.loads(line)
        except ValueError:
            return False
        return isinstance(message, dict) and message.get("id") == want_id and ("result" in message or "error" in message)
    return ready


acp_ready = acp_response(1)


def init_then_session(work):
    """`initialize` and `session/new` back to back, as a client that wants a session."""
    session = {"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": str(work), "mcpServers": []}}
    return INIT + json.dumps(session).encode() + b"\n"


def repl_ready(tag, line):
    return tag == "err" and line.startswith("[shutdown") and "final-save" in line


POINTS = {
    # name: argv tail, kind, metric names, key, extra env, ready predicate, stdin
    "a_version": (["--version"], "wall", True, {}, None, None),
    "a_help": (["--help"], "wall", True, {}, None, None),
    # The only REPL "loop reached" stamp is the shutdown trace; acceptable debug env.
    "b_repl_ready": (["--model", "lmstudio"], "stream", True, {"GRAFF_SHUTDOWN_DEBUG": "1"}, repl_ready, None),
    "c_first_request": (["-p", "hi", "--model", "lmstudio"], "post", True, {}, None, None),
    "d_acp_initialize": (["acp", "--model", "lmstudio"], "stream", True, {}, acp_ready, INIT),
    "d_acp_initialize_nokey": (["acp"], "stream", False, {}, acp_ready, INIT),
    "d_acp_session_usable": (["acp", "--model", "lmstudio"], "stream", True, {}, acp_response(2), init_then_session),
}
READY_METRIC = {"b_repl_ready": "ready_ms", "c_first_request": "request_ms",
                "d_acp_initialize": "response_ms", "d_acp_initialize_nokey": "response_ms",
                "d_acp_session_usable": "response_ms"}


class ForeignRequest(BenchError):
    pass


def stdin_for(stdin_data, work):
    return stdin_data(work) if callable(stdin_data) else stdin_data


def sample(fx, mock, binary, name, template, timeout, extra=None, path=None):
    """One timed run; redone when a stray client posted to the shared mock port."""
    for attempt in range(FOREIGN_RETRIES + 1):
        try:
            return sample_once(fx, mock, binary, name, template, timeout, extra, path)
        except ForeignRequest as exc:
            fx.foreign_retries = getattr(fx, "foreign_retries", 0) + 1
            if attempt == FOREIGN_RETRIES:
                raise BenchError(f"{exc} (still after {FOREIGN_RETRIES} retries)") from exc


def sample_once(fx, mock, binary, name, template, timeout, extra=None, path=None):
    tail_argv, kind, key, env_extra, ready, stdin_data = POINTS[name]
    dest, home, work = fx.fresh(template)
    token = f"local-bench-{os.getpid()}-{fx.counter}"
    env = fx.env(home, key=key, extra=dict(env_extra, **(extra or {})), path=path)
    if key:
        env["LMSTUDIO_API_KEY"] = token
    mine = (lambda auth: auth == f"Bearer {token}") if key else (lambda auth: auth is None)
    argv = [binary] + tail_argv
    with mock._lock:
        before = len(mock.posts)
    try:
        if kind == "stream":
            got = run_stream(argv, env, str(work), timeout, ready, stdin_for(stdin_data, work))
            row = {READY_METRIC[name]: got["ready_ms"], "wall_ms": got["wall_ms"], "cpu_ms": got["cpu_ms"]}
            lines = got["lines"]
            if name.startswith("d_"):
                reply = next(json.loads(l) for _, t, l in lines if t == "out" and ready(t, l))
                if "result" not in reply:
                    raise BenchError(f"{name}: the request returned an error: {reply.get('error')}")
        else:
            got = run_wall(argv, env, str(work), timeout, str(dest / "stderr"))
            if got["rc"] != 0:
                raise BenchError(f"{name}: exit {got['rc']}\n{tail(dest / 'stderr')}")
            row = {"wall_ms": got["wall_ms"], "cpu_ms": got["cpu_ms"]}
            lines = [(0, "err", l) for l in tail(dest / "stderr", 1 << 20).splitlines()]
        with mock._lock:
            seen = mock.posts[before:]
        posts = [stamp for stamp, auth in seen if mine(auth)]
        if len(posts) != len(seen):
            raise ForeignRequest(f"{name}: {len(seen) - len(posts)} request(s) from another client on the mock port")
        if kind == "post":
            if not posts:
                raise BenchError(f"{name}: the mock never received a request\n{tail(dest / 'stderr')}")
            row["request_ms"] = (posts[0] - got["started"]) / 1e6
        elif posts:
            raise BenchError(f"{name}: unexpected model request ({len(posts)}) during startup")
        row["posts"] = len(posts)
        return row, lines
    finally:
        shutil.rmtree(dest, ignore_errors=True)


def floor_sample(fx, prog, timeout):
    work = fx.root / "floorcwd"
    work.mkdir(exist_ok=True)
    return run_wall([prog], fx.env(fx.root), str(work), timeout, str(fx.root / "floor.err"))["wall_ms"]


def measure(args, binary):
    mock = start_mock()
    fx = None
    try:
        fx = Fixture(args)
        names = [n for n in POINTS if n in args.points]
        templates = {n: fx.template(n) for n in names if not n.startswith("a_")}
        a_template = fx.template("a")
        for n in names:
            templates.setdefault(n, a_template)
        per_round = {n: (math.ceil(100 / args.runs) if n.startswith("a_") else 1) for n in names}
        floors = [("true_ms", "/usr/bin/true")] + ([("hello_ms", fx.hello)] if fx.hello else [])
        samples = {n: {} for n in names}
        floor_samples = {k: [] for k, _ in floors}
        load = [os.getloadavg()[0]]

        def log(msg):
            if not args.quiet:
                print(msg, file=sys.stderr, flush=True)

        # Warm-up runs in the templates so each copied sample sees steady state.
        for _ in range(args.warmup):
            for n in names:
                tail_argv, kind, key, env_extra, ready, stdin_data = POINTS[n]
                home, work = templates[n]
                env = fx.env(home, key=key, extra=env_extra)
                if kind == "stream":
                    run_stream([binary] + tail_argv, env, str(work), args.timeout, ready, stdin_for(stdin_data, work))
                else:
                    run_wall([binary] + tail_argv, env, str(work), args.timeout, str(fx.root / "warm.err"))
            for _, prog in floors:
                floor_sample(fx, prog, args.timeout)
        # Timing pass: interleaved rounds, rotated order, no debug env except b's marker.
        order = [("floor", k, p) for k, p in floors] + [("point", n, None) for n in names]
        for r in range(args.runs):
            rotated = order[r % len(order):] + order[:r % len(order)]
            for kind, n, prog in rotated:
                if kind == "floor":
                    for _ in range(math.ceil(50 / args.runs)):
                        floor_samples[n].append(floor_sample(fx, prog, args.timeout))
                    continue
                for _ in range(per_round[n]):
                    row, _ = sample(fx, mock, binary, n, templates[n], args.timeout)
                    for metric, value in row.items():
                        samples[n].setdefault(metric, []).append(value)
            log(f"round {r + 1}/{args.runs}")
        load.append(os.getloadavg()[0])
        points = {}
        for n in names:
            points[n] = {m: stats(v) for m, v in samples[n].items() if m != "posts"}
            points[n]["model_requests"] = max(samples[n].get("posts", [0]))
        # Diagnostic pass: per-phase medians from GRAFF_BOOT_DEBUG.
        for n in names:
            if n.startswith("a_") or args.diag_runs <= 0:
                continue
            phases = {}
            for _ in range(args.diag_runs):
                _, lines = sample(fx, mock, binary, n, templates[n], args.timeout, {"GRAFF_BOOT_DEBUG": "1"})
                seen = {}
                for _, tag, line in lines:
                    match = BOOT_LINE.match(line) if tag == "err" else None
                    if match:
                        seen[match.group(3)] = seen.get(match.group(3), 0) + int(match.group(2))
                for label, ms in seen.items():
                    phases.setdefault(label, []).append(ms)
            points[n]["phases_ms"] = {k: statistics.median(v) for k, v in phases.items()}
            log(f"diag {n}")
        # Spawn pass: PATH shims log every git/security/companion spawn.
        roots = [str(fx.root), os.path.realpath(str(fx.root))]
        for n in names:
            runs = []
            for _ in range(max(1, args.shim_runs)):
                if fx.log.exists():
                    fx.log.unlink()
                sample(fx, mock, binary, n, templates[n], args.timeout, path=fx.shim_path)
                runs.append(parse_spawns(fx.log, roots))
            tools = ["git", "security"] + sorted(fx.companions)
            counts = {t: max(c.get(t, 0) for c, _ in runs) for t in tools}
            points[n]["spawns"] = counts
            if any(c != runs[0][0] for c, _ in runs):
                points[n]["spawns_nondeterministic"] = [c for c, _ in runs]
            points[n]["spawn_detail"] = runs[0][1]
            for line in runs[0][1]:
                if line.startswith("git ") and any(f" {cmd}" in line for cmd in FORBIDDEN_GIT):
                    raise BenchError(f"{n}: network/auto-isolation git command observed: {line}")
            log(f"spawns {n}: {counts}")
        return {"floor": {k: stats(v) for k, v in floor_samples.items()}, "points": points,
                "samples": {"floor": floor_samples, **samples}, "load": load,
                "path_dirs": ["<bench>/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"],
                "companions": sorted(fx.companions), "git": fx.git_version,
                "foreign_retries": getattr(fx, "foreign_retries", 0)}
    finally:
        for pid in list(LIVE):
            reap_group(pid)
        mock.stop()
        if fx is not None:
            fx.cleanup()



def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--graff", type=Path, default=root / "zig-out/bin/graff")
    parser.add_argument("--runs", type=int, default=30, help="timed rounds (a_* points take ≥100 samples)")
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--diag-runs", type=int, default=5, help="GRAFF_BOOT_DEBUG runs per point (0 to skip)")
    parser.add_argument("--shim-runs", type=int, default=2, help="spawn-counting runs per point")
    parser.add_argument("--timeout", type=float, default=30, help="per-run deadline in seconds")
    parser.add_argument("--points", default=",".join(POINTS), help="comma-separated subset")
    parser.add_argument("--git-repo", action="store_true", help="cwd is a throwaway one-commit repo, no remote")
    parser.add_argument("--companion", action="store_true", help="put codedb-pro/muonry on PATH")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE",
                        help="extra child env (knob experiments); safety vars cannot be overridden")
    parser.add_argument("--out", type=Path, help="write the result JSON here")
    parser.add_argument("--load", type=Path, help="use an existing result instead of measuring")
    parser.add_argument("--compare", type=Path, help="print deltas against an earlier result")
    parser.add_argument("--budgets", type=Path, help="gate on ratio-over-floor and spawn counts")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    args.extra_env = {}
    for item in args.env:
        k, sep, v = item.partition("=")
        if not sep or not k:
            parser.error(f"--env wants KEY=VALUE, got {item!r}")
        if k in PROTECTED:
            parser.error(f"--env may not override {k}")
        args.extra_env[k] = v
    args.points = [p.strip() for p in args.points.split(",") if p.strip()]
    unknown = [p for p in args.points if p not in POINTS]
    if unknown:
        parser.error(f"unknown points {unknown}; choose from {list(POINTS)}")
    if args.runs < 1 or args.warmup < 0 or args.timeout <= 0:
        parser.error("runs ≥ 1, warmup ≥ 0, timeout > 0")

    if args.load:
        result = json.loads(args.load.read_text())
    else:
        if not args.out:
            parser.error("--out is required unless --load is given")
        binary = os.path.realpath(str(args.graff))
        if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
            raise BenchError(f"graff binary not found or not executable: {args.graff} "
                             "(build with: zig build graff -Doptimize=ReleaseSafe -Dlearn=false)")
        data = Path(binary).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        cwd = os.getcwd()
        try:
            try:
                with tempfile.TemporaryDirectory(prefix="graff-startup-version-") as scratch:
                    version = subprocess.run(
                        [binary, "--version"], capture_output=True, text=True, timeout=10, cwd=scratch,
                        env={"PATH": "/usr/bin:/bin", "HOME": scratch, "GRAFF_NO_TELEMETRY": "1",
                             "GRAFF_NO_UPDATE_CHECK": "1", "GRAFF_AUTO_ISOLATE": "off"},
                    ).stdout.strip().splitlines()[:1]
            except subprocess.TimeoutExpired as exc:
                raise BenchError(f"{binary} --version did not exit within 10s") from exc
            measured = measure(args, binary)
        finally:
            os.chdir(cwd)
        if hashlib.sha256(Path(binary).read_bytes()).hexdigest() != digest:
            raise BenchError("binary changed during measurement; rerun against a stable copy")
        result = {
            "schema": SCHEMA,
            "graff": {"path": binary, "sha256": digest, "size": len(data), "version": (version or [""])[0]},
            "host": {"os": platform.system(), "release": platform.release(), "arch": platform.machine(),
                     "cpu": cpu_name(), "ncpu": os.cpu_count(), "python": platform.python_version(),
                     "load1": measured["load"]},
            "env": {"hermetic": True, "git_repo": args.git_repo, "companion": args.companion,
                    "companions_found": measured["companions"], "auto_isolate": "off",
                    "git": measured["git"], "foreign_retries": measured["foreign_retries"],
                    "extra_env": sorted(args.extra_env), "path": measured["path_dirs"],
                    "security": "stub (exit 44, Keychain never read)",
                    "debug_env": {"b_repl_ready": "GRAFF_SHUTDOWN_DEBUG=1 (ready marker)",
                                  "phases_ms": "GRAFF_BOOT_DEBUG=1 (separate diagnostic pass)"}},
            "timer": {"method": "os.posix_spawn + wait4, perf_counter_ns from before spawn",
                      "note": "includes the interpreter's spawn cost; subtract floor.*.median for graff-only time"},
            "runs": args.runs, "warmup": args.warmup, "diag_runs": args.diag_runs, "shim_runs": args.shim_runs,
            "floor": measured["floor"], "points": measured["points"], "samples": measured["samples"],
        }
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, indent=1) + "\n")
    print_summary(result)
    if args.compare:
        print()
        compare(json.loads(args.compare.read_text()), result)
    if args.budgets:
        print()
        failures = check_budgets(result, json.loads(args.budgets.read_text()))
        if failures:
            print(f"startup budgets exceeded: {', '.join(failures)}")
            return 1
    return 0


def _terminate(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _terminate)
    try:
        code = main()
    except BenchError as exc:
        print(f"bench-startup: {exc}", file=sys.stderr)
        code = 2
    except KeyboardInterrupt:
        code = 130
    finally:
        for pid in list(LIVE):
            reap_group(pid)
    sys.exit(code)
