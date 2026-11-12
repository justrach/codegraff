"""Process, fixture and report helpers for scripts/bench-startup.py.

Split out of the benchmark script (hand-written files stay under 600 lines);
behaviour is unchanged. Nothing here is a benchmark point: the points, the
sampling loop and the CLI live in bench-startup.py.
"""
from __future__ import annotations

import math
import os
import platform
import queue
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
PORT = 1234  # the built-in lmstudio provider URL is fixed to 127.0.0.1:1234
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
