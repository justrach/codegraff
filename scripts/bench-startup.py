#!/usr/bin/env python3
"""Hermetic cold-start benchmark for graff; see docs/harness-latency.md.

Times four ready points from process spawn, with no network and no credentials:
  a_version / a_help   `--version` / `--help` exit (wall)
  b_repl_ready         line REPL reaches its loop (stdin=/dev/null; first
                       GRAFF_SHUTDOWN_DEBUG `final-save` stamp on stderr)
  c_first_request      `-p hi --model lmstudio`: first POST at the loopback mock
  d_acp_initialize     `graff acp`: the `initialize` response line on stdout
                       (`_nokey` variant: no credential, pre-auth path)
plus a floor (/usr/bin/true and a compiled C hello) timed the same way.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import queue
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from mock_model import ScriptedModel  # noqa: E402

clock = time.perf_counter_ns
SCHEMA = 1
PORT = 1234  # the built-in lmstudio provider URL is fixed to 127.0.0.1:1234
INIT = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}\n'
BOOT_LINE = re.compile(r"^\[boot \+(\d+)ms, phase (\d+)ms\] (.+)$")
# Safety vars are fixed; --env may not override them.
PROTECTED = {"HOME", "PATH", "GRAFF_NO_TELEMETRY", "GRAFF_NO_UPDATE_CHECK", "GRAFF_AUTO_ISOLATE",
             "LMSTUDIO_API_KEY"}
# Git subcommands that reach a remote or mean auto-isolation fired. Any of them fails the run.
FORBIDDEN_GIT = ("fetch", "pull", "push", "clone", "ls-remote", "remote update", "worktree add")
LIVE = set()  # process groups still to reap on exit


class BenchError(Exception):
    pass


# ---------------------------------------------------------------- processes

def spawn(argv, env, cwd, stdin=None, stdout=None, stderr=None):
    """os.posix_spawn in its own process group. ~1 ms floor versus ~2.7 ms for
    subprocess on macOS, so less interpreter overhead lands in the timer.
    stdin/stdout/stderr: None for /dev/null, else an fd to dup2."""
    actions = []
    for target, fd in ((0, stdin), (1, stdout), (2, stderr)):
        if fd is None:
            flags = os.O_RDONLY if target == 0 else os.O_WRONLY
            actions.append((os.POSIX_SPAWN_OPEN, target, os.devnull, flags, 0))
        else:
            actions.append((os.POSIX_SPAWN_DUP2, fd, target))
    os.chdir(cwd)  # posix_spawn has no chdir action before Python 3.13
    pid = os.posix_spawn(argv[0], argv, env, file_actions=actions, setpgroup=0)
    LIVE.add(pid)
    return pid


def reap_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass
    LIVE.discard(pid)


class Watchdog:
    """Kills the process group at the deadline so a stuck run cannot hang."""
    def __init__(self, timeout):
        self.fired = False
        self.pid = None
        self.timer = threading.Timer(timeout, self._fire)
        self.timer.daemon = True
        self.timer.start()

    def _fire(self):
        self.fired = True
        if self.pid is not None:
            reap_group(self.pid)

    def cancel(self):
        self.timer.cancel()


def wait_child(pid, dog):
    _, status, usage = os.wait4(pid, 0)
    ended = clock()
    dog.cancel()
    reap_group(pid)  # stray grandchildren (git, companions) must not outlive the sample
    rc = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (
        -os.WTERMSIG(status) if os.WIFSIGNALED(status) else os.WEXITSTATUS(status))
    return ended, rc, (usage.ru_utime + usage.ru_stime) * 1e3


def tail(path, limit=1200):
    try:
        return Path(path).read_text(errors="replace")[-limit:]
    except OSError:
        return ""


def run_wall(argv, env, cwd, timeout, errfile):
    """Spawn → exit. stdout to /dev/null, stderr to errfile (for failure reports)."""
    errfd = os.open(errfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    dog = Watchdog(timeout)
    try:
        started = clock()
        pid = dog.pid = spawn(argv, env, cwd, stderr=errfd)
    except OSError:
        dog.cancel()
        raise
    finally:
        os.close(errfd)
    ended, rc, cpu = wait_child(pid, dog)
    if dog.fired:
        raise BenchError(f"{' '.join(argv[1:]) or argv[0]}: no exit within {timeout}s\n{tail(errfile)}")
    return {"started": started, "wall_ms": (ended - started) / 1e6, "cpu_ms": cpu, "rc": rc}


def _reader(fd, tag, events):
    buf = b""
    while True:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        stamp = clock()
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            events.put((stamp, tag, line.decode(errors="replace")))
    if buf:
        events.put((clock(), tag, buf.decode(errors="replace")))
    events.put((clock(), tag, None))
    os.close(fd)


def run_stream(argv, env, cwd, timeout, ready, stdin_data=None):
    """Spawn, optionally write stdin_data (stdin stays open), and stamp the first
    line where ready(tag, line) holds. Then close stdin and time the exit."""
    events = queue.Queue()
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    in_r, in_w = os.pipe() if stdin_data is not None else (None, None)
    readers = [threading.Thread(target=_reader, args=(fd, tag, events), daemon=True)
               for fd, tag in ((out_r, "out"), (err_r, "err"))]
    for thread in readers:
        thread.start()
    dog = Watchdog(timeout)
    try:
        started = clock()
        pid = dog.pid = spawn(argv, env, cwd, stdin=in_r, stdout=out_w, stderr=err_w)
    except OSError:
        dog.cancel()  # readers see EOF once the finally below closes the write ends
        if in_w is not None:
            os.close(in_w)
        raise
    finally:
        for fd in (out_w, err_w, in_r):
            if fd is not None:
                os.close(fd)
    deadline = time.monotonic() + timeout
    lines, ready_at, eofs = [], None, 0
    try:
        if stdin_data is not None:
            os.write(in_w, stdin_data)
        while ready_at is None and eofs < 2:
            try:
                stamp, tag, line = events.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                break
            if line is None:
                eofs += 1
                continue
            lines.append((stamp, tag, line))
            if ready(tag, line):
                ready_at = stamp
    finally:
        if in_w is not None:
            try:
                os.close(in_w)
            except OSError:
                pass
        if ready_at is None:
            reap_group(pid)  # unblock wait4 now rather than at the watchdog deadline
    ended, rc, cpu = wait_child(pid, dog)
    for thread in readers:
        thread.join(timeout=2)
    while True:
        try:
            stamp, tag, line = events.get_nowait()
        except queue.Empty:
            break
        if line is not None:
            lines.append((stamp, tag, line))
    stderr_tail = "\n".join(l for _, t, l in lines if t == "err")[-1200:]
    if ready_at is None:
        why = "timed out" if time.monotonic() >= deadline or dog.fired else f"exited rc={rc}"
        raise BenchError(f"{' '.join(argv[1:])}: ready marker never appeared ({why})\n{stderr_tail}")
    return {"started": started, "ready_ms": (ready_at - started) / 1e6,
            "wall_ms": (ended - started) / 1e6, "cpu_ms": cpu, "rc": rc, "lines": lines}


# ---------------------------------------------------------------- fixtures

class Mock(ScriptedModel):
    """scripts/eval/mock_model.py, plus a perf_counter_ns stamp per POST. The
    stamp is taken once the request body has been read (loopback, sub-ms)."""
    def __init__(self):
        super().__init__([])
        self.posts = []

    def next_reply(self, body):
        stamp = clock()
        with self._lock:
            self.posts.append(stamp)
        return super().next_reply(body)


def start_mock():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(0.3)
    try:
        if probe.connect_ex(("127.0.0.1", PORT)) == 0:
            raise BenchError(f"127.0.0.1:{PORT} is busy (LM Studio or another mock?). The lmstudio "
                             "provider is fixed to that port; stop the listener and rerun.")
    finally:
        probe.close()
    mock = Mock()
    try:
        mock.start(PORT)
    except OSError as exc:
        raise BenchError(f"cannot bind 127.0.0.1:{PORT}: {exc}") from exc
    return mock


def which_in(name, path):
    found = shutil.which(name, path=path)
    return os.path.realpath(found) if found else None


def write_exe(path, text):
    path.write_text(text)
    path.chmod(0o755)


class Fixture:
    """Scratch tree: bin/ (timing PATH), shim/ (spawn-logging PATH), template
    HOME and cwd per point. Each sample runs in fresh copies of the templates."""
    def __init__(self, args):
        self.root = Path(tempfile.mkdtemp(prefix="graff-startup-")).resolve()
        try:
            self._setup(args)
        except BaseException:
            self.cleanup()
            raise

    def _setup(self, args):
        self.args = args
        user_path = os.environ.get("PATH", "")
        self.git = which_in("git", user_path)
        if not self.git:
            raise BenchError("git not found on PATH")
        if sys.platform == "darwin" and self.git == "/usr/bin/git":
            # /usr/bin/git is the xcrun shim: its first call under each new HOME
            # costs ~70-110 ms (then ~11 ms). Every sample has a fresh HOME, so
            # the shim would bill that to graff on every run. Use the real git.
            found = subprocess.run(["xcrun", "--find", "git"], capture_output=True, text=True).stdout.strip()
            if found and os.access(found, os.X_OK):
                self.git = found
        self.git_version = subprocess.run([self.git, "--version"], capture_output=True,
                                          text=True).stdout.strip()
        self.bin = self.root / "bin"
        self.shim = self.root / "shim"
        self.log = self.root / "spawns.log"
        self.bin.mkdir()
        self.shim.mkdir()
        os.symlink(self.git, self.bin / "git")
        # Never reach the real Keychain: answer "not found" (44) like an empty one.
        stub = "#!/bin/sh\n{log}echo 'security: The specified item could not be found in the keychain.' >&2\nexit 44\n"
        write_exe(self.bin / "security", stub.format(log=""))
        write_exe(self.shim / "security", stub.format(log=f'printf "%s\\n" "security $*" >> "{self.log}"\n'))
        write_exe(self.shim / "git", f'#!/bin/sh\nprintf "%s\\n" "git $*" >> "{self.log}"\nexec "{self.git}" "$@"\n')
        self.companions = {}
        if args.companion:
            for name in ("codedb-pro", "muonry"):
                real = which_in(name, user_path)
                if real:
                    self.companions[name] = real
                    os.symlink(real, self.bin / name)
                    write_exe(self.shim / name, f'#!/bin/sh\nprintf "%s\\n" "{name} $*" >> "{self.log}"\nexec "{real}" "$@"\n')
            if "codedb-pro" not in self.companions:
                raise BenchError("--companion needs codedb-pro on PATH")
        self.path = os.pathsep.join([str(self.bin), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        self.shim_path = str(self.shim) + os.pathsep + self.path
        self.hello = None
        cc = which_in("cc", user_path)
        if cc:
            (self.root / "hello.c").write_text('#include <unistd.h>\nint main(void){write(1,"hi\\n",3);return 0;}\n')
            if subprocess.run([cc, "-O2", "-o", str(self.root / "hello"), str(self.root / "hello.c")],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                self.hello = str(self.root / "hello")
        self.counter = 0

    def env(self, home, key=True, extra=None, path=None):
        env = {k: os.environ[k] for k in ("TMPDIR", "TERM") if k in os.environ}
        env.update(PATH=path or self.path, HOME=str(home), GRAFF_NO_TELEMETRY="1",
                   GRAFF_NO_UPDATE_CHECK="1", GRAFF_AUTO_ISOLATE="off", GRAFF_FLEET="off",
                   GRAFF_NO_SMOLIFY="1", GRAFF_LEARN_AUTO="off", NO_COLOR="1")
        if key:
            env["LMSTUDIO_API_KEY"] = "local"
        env.update(self.args.extra_env)
        env.update(extra or {})
        return env

    def git_env(self, home):
        return dict(self.env(home, key=False), GIT_CONFIG_NOSYSTEM="1")

    def template(self, name):
        base = self.root / "templates" / name
        home, work = base / "home", base / "work"
        home.mkdir(parents=True)
        work.mkdir()
        genv = self.git_env(home)
        if self.args.git_repo:
            (work / "README.md").write_text("startup benchmark fixture\n")
            for cmd in (["init", "-q"], ["add", "README.md"],
                        ["-c", "user.name=bench", "-c", "user.email=bench@example.invalid",
                         "-c", "commit.gpgsign=false", "commit", "-q", "-m", "fixture"]):
                subprocess.run([self.git] + cmd, cwd=work, env=genv, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            inside = subprocess.run([self.git, "rev-parse", "--is-inside-work-tree"], cwd=work, env=genv,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if inside:
                raise BenchError(f"scratch dir {work} is inside a git repository; set TMPDIR elsewhere")
        return home, work

    def fresh(self, template):
        """Copy a template HOME+cwd so every sample sees identical state."""
        self.counter += 1
        dest = self.root / "runs" / str(self.counter)
        home = dest / "home"
        work = dest / "work"
        shutil.copytree(template[0], home, symlinks=True)
        shutil.copytree(template[1], work, symlinks=True)
        return dest, home, work

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


# ---------------------------------------------------------------- points

def acp_ready(tag, line):
    if tag != "out":
        return False
    try:
        message = json.loads(line)
    except ValueError:
        return False
    return message.get("id") == 1 and ("result" in message or "error" in message)


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
}
READY_METRIC = {"b_repl_ready": "ready_ms", "c_first_request": "request_ms",
                "d_acp_initialize": "response_ms", "d_acp_initialize_nokey": "response_ms"}


def sample(fx, mock, binary, name, template, timeout, extra=None, path=None):
    tail_argv, kind, key, env_extra, ready, stdin_data = POINTS[name]
    dest, home, work = fx.fresh(template)
    env = fx.env(home, key=key, extra=dict(env_extra, **(extra or {})), path=path)
    argv = [binary] + tail_argv
    with mock._lock:
        before = len(mock.posts)
    try:
        if kind == "stream":
            got = run_stream(argv, env, str(work), timeout, ready, stdin_data)
            row = {READY_METRIC[name]: got["ready_ms"], "wall_ms": got["wall_ms"], "cpu_ms": got["cpu_ms"]}
            lines = got["lines"]
            if name.startswith("d_"):
                reply = next(json.loads(l) for _, t, l in lines if t == "out" and acp_ready(t, l))
                if "result" not in reply:
                    raise BenchError(f"{name}: initialize returned an error: {reply.get('error')}")
        else:
            got = run_wall(argv, env, str(work), timeout, str(dest / "stderr"))
            if got["rc"] != 0:
                raise BenchError(f"{name}: exit {got['rc']}\n{tail(dest / 'stderr')}")
            row = {"wall_ms": got["wall_ms"], "cpu_ms": got["cpu_ms"]}
            lines = [(0, "err", l) for l in tail(dest / "stderr", 1 << 20).splitlines()]
        with mock._lock:
            posts = mock.posts[before:]
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


def stats(values):
    ordered = sorted(values)
    if not ordered:
        return {"n": 0}
    pick = lambda q: ordered[max(0, math.ceil(len(ordered) * q) - 1)]  # noqa: E731
    return {"n": len(ordered), "min": round(ordered[0], 3), "median": round(statistics.median(ordered), 3),
            "p95": round(pick(0.95), 3), "max": round(ordered[-1], 3)}


def parse_spawns(log, roots):
    counts, detail = {}, []
    if log.exists():
        for line in log.read_text(errors="replace").splitlines():
            tool = line.split(" ", 1)[0]
            counts[tool] = counts.get(tool, 0) + 1
            for root in roots:
                line = line.replace(root, "<tmp>")
            detail.append(line)
    return counts, detail


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
                    run_stream([binary] + tail_argv, env, str(work), args.timeout, ready, stdin_data)
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
                "companions": sorted(fx.companions), "git": fx.git_version}
    finally:
        for pid in list(LIVE):
            reap_group(pid)
        mock.stop()
        if fx is not None:
            fx.cleanup()


# ---------------------------------------------------------------- report

def cpu_name():
    try:
        if sys.platform == "darwin":
            return subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True,
                                  text=True, timeout=5).stdout.strip()
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return platform.processor()


def floor_ref(result):
    floor = result.get("floor", {})
    for key in ("hello_ms", "true_ms"):
        if floor.get(key, {}).get("n"):
            return key, floor[key]["median"]
    return None, None


def headline(result):
    rows = []
    for name, point in result["points"].items():
        for metric, value in point.items():
            if isinstance(value, dict) and "median" in value and metric != "cpu_ms":
                rows.append((f"{name}.{metric}", value))
    return rows


def print_summary(result):
    key, floor = floor_ref(result)
    print(f"floor {key}: median {floor} ms (subtract for graff-only cost)" if floor else "floor: none")
    for k, v in result["floor"].items():
        print(f"  {k:28} n={v['n']:3} min {v['min']:8.2f} med {v['median']:8.2f} p95 {v['p95']:8.2f}")
    for label, v in headline(result):
        print(f"  {label:44} n={v['n']:3} min {v['min']:8.2f} med {v['median']:8.2f} p95 {v['p95']:8.2f} max {v['max']:8.2f}")
    for name, point in result["points"].items():
        if "spawns" in point:
            print(f"  {name:44} spawns {point['spawns']}")


def variant(result):
    env = result.get("env", {})
    return "git_repo" if env.get("git_repo") else "default"


def compare(before, after):
    if variant(before) != variant(after) or before["env"].get("companion") != after["env"].get("companion"):
        print("WARNING: comparing different variants (git_repo/companion differ)")
    if before.get("host", {}).get("cpu") != after.get("host", {}).get("cpu"):
        print("WARNING: different hosts")
    _, fb = floor_ref(before)
    _, fa = floor_ref(after)
    print(f"{'point.metric':44} {'before':>9} {'after':>9} {'delta':>9} {'delta%':>7}   net(before→after)")
    old = dict(headline(before))
    for label, v in headline(after):
        if label not in old:
            continue
        b, a = old[label]["median"], v["median"]
        net = f"{b - (fb or 0):7.2f}→{a - (fa or 0):.2f}"
        pct = (a - b) / b * 100 if b else 0.0
        print(f"{label:44} {b:9.2f} {a:9.2f} {a - b:+9.2f} {pct:+6.1f}%   {net}")
    for name, point in after["points"].items():
        prev = before["points"].get(name, {}).get("spawns")
        if prev is not None and "spawns" in point and prev != point["spawns"]:
            print(f"{name + ' spawns':44} {prev} → {point['spawns']}")


def check_budgets(result, budgets):
    failures, notes = [], []
    key, floor = floor_ref(result)
    if budgets.get("floor") and budgets["floor"] != key:
        notes.append(f"budget floor {budgets['floor']} unavailable; using {key}")
    for label, rule in budgets.get("ratio_over_floor", {}).items():
        if label.startswith("_"):
            continue
        name, metric = label.split(".", 1)
        stat = result["points"].get(name, {}).get(metric)
        if not stat or not floor:
            notes.append(f"skip {label}: not measured")
            continue
        ratio = stat["median"] / floor
        status = "ok" if ratio <= rule["max"] else "FAIL"
        print(f"budget {label:40} ratio {ratio:6.1f} ≤ {rule['max']:<6} {status}")
        if status != "ok":
            failures.append(label)
    for name, tools in budgets.get("spawns", {}).get(variant(result), {}).items():
        if name.startswith("_"):
            continue
        point = result["points"].get(name, {})
        if "spawns" not in point:
            notes.append(f"skip {name} spawns: not measured")
            continue
        for tool, rule in tools.items():
            if tool.startswith("_"):
                continue
            limit = rule["max"] if isinstance(rule, dict) else rule
            got = point["spawns"].get(tool, 0)
            status = "ok" if got <= limit else "FAIL"
            print(f"budget {name + ' ' + tool + ' spawns':40} {got:6} ≤ {limit:<6} {status}")
            if status != "ok":
                failures.append(f"{name}.{tool}")
    for note in notes:
        print(note)
    return failures


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
                    "git": measured["git"],
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
