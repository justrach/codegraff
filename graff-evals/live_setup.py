"""Materialize a live-eval sandbox: sparse package checkout, no SPEC.md.

Refuses to start if the public check is already green on the parent tree
(G1 / G6). Historical July 2026 parents do not compile on Zig 0.17; those
tasks use a reconstructed parent (current package minus the fix) so the
gates are real. See artifacts/graff-evals-live/LIVE.md.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

EVALS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(EVALS)

# Never copy these into a live sandbox (spoilers + eval machinery).
SKIP_DIRS = {
    ".git", ".sandboxes", "graff-evals", "artifacts", "docs", "apps",
    "node_modules", "zig-out", "zig-cache", ".zig-cache", "__pycache__",
    "results", "evals",
}

# Enough of the package to `zig build test`. Not the function, not graff-evals.
DEFAULT_SPARSE = (
    "build.zig", "build.zig.zon", "src", "vendor", "TUI",
    "spec", "examples", "assets", "scripts",
    "gui/public/favicon.png",
)


def load_catalog():
    with open(os.path.join(EVALS, "live", "catalog.json")) as f:
        return json.load(f)


def manifest(task_id):
    cat = load_catalog()
    for t in cat["published"] + cat.get("reserve", []) + cat.get("dropped", []):
        if t["id"] == task_id:
            return t
    raise SystemExit(f"unknown live task: {task_id}")


def _copy_sparse(src_root, dest, paths):
    for rel in paths:
        src = os.path.join(src_root, rel)
        dst = os.path.join(dest, rel)
        if not os.path.exists(src):
            continue
        os.makedirs(os.path.dirname(dst) or dest, exist_ok=True)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True, ignore=shutil.ignore_patterns(
                "__pycache__", ".DS_Store", "*.pyc", "zig-cache", ".zig-cache"))
        else:
            shutil.copy2(src, dst)


def copy_local_package(dest, paths=None):
    _copy_sparse(REPO, dest, paths or DEFAULT_SPARSE)


def run_public(task, sandbox, timeout=None):
    script = os.path.join(EVALS, "live", task["id"], "check_public.sh")
    env = dict(os.environ, TASK_ROOT=EVALS)
    return subprocess.run(["/bin/sh", script], cwd=sandbox, capture_output=True,
                          text=True, timeout=timeout or task.get("check_timeout_s", 180),
                          env=env)


def run_hidden(task, sandbox, timeout=None):
    hidden = task.get("hidden")
    if not hidden:
        return subprocess.CompletedProcess([], 0, "", "")
    path = hidden if os.path.isabs(hidden) else os.path.join(EVALS, hidden)
    env = dict(os.environ, TASK_ROOT=EVALS)
    return subprocess.run(["/bin/sh", path], cwd=sandbox, capture_output=True,
                          text=True, timeout=timeout or task.get("check_timeout_s", 180),
                          env=env)


def _drop_build_cache(sandbox):
    for stale in (".zig-cache", "zig-out"):
        p = os.path.join(sandbox, stale)
        if os.path.exists(p):
            shutil.rmtree(p)


def apply_parent(task, sandbox):
    breaker = os.path.join(EVALS, "live", task["id"], "break_parent.py")
    if os.path.exists(breaker):
        subprocess.check_call([sys.executable, breaker, sandbox])
        _drop_build_cache(sandbox)


def apply_grease(task, sandbox):
    grease = os.path.join(EVALS, "live", task["id"], "grease.py")
    if not os.path.exists(grease):
        raise SystemExit(f"{task['id']}: missing grease.py (G3)")
    subprocess.check_call([sys.executable, grease, sandbox])
    _drop_build_cache(sandbox)


def spoilers_in(sandbox):
    """G5: SPEC.md or builder-brief text must not land in the exam tree."""
    hits = []
    skip = {".eval-answer.txt"}
    needles = ("SPEC.md",)
    text_needles = (
        "LIVE.md",
        "check_public.sh",
        "graff-evals/hidden",
        "this is the hidden case",
    )
    for root, dirs, files in os.walk(sandbox):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and d != ".git"]
        for name in files:
            if name in skip or name.endswith((".png", ".o", ".a")):
                continue
            rel = os.path.relpath(os.path.join(root, name), sandbox)
            if name in needles or name == "SPEC.md":
                hits.append(rel)
                continue
            path = os.path.join(root, name)
            try:
                body = open(path, errors="replace").read(200_000)
            except OSError:
                continue
            for n in text_needles:
                if n in body:
                    hits.append(f"{rel}:{n}")
    return hits


def clone_historical_parent(task, dest):
    repo = task["repo"]
    sha = task["historical_parent"]
    cache_root = os.environ.get("GRAFF_LIVE_CACHE", "/tmp/graff-live-repos")
    cache = os.path.join(cache_root, repo.replace("/", "_"))
    url = f"https://github.com/{repo}.git"
    os.makedirs(cache_root, exist_ok=True)
    if not os.path.isdir(os.path.join(cache, ".git")):
        subprocess.check_call(["git", "clone", "--filter=blob:none", url, cache], timeout=180)
    subprocess.check_call(["git", "-C", cache, "fetch", "--filter=blob:none", "origin", sha], timeout=120)
    archive = subprocess.Popen(["git", "-C", cache, "archive", sha], stdout=subprocess.PIPE)
    subprocess.check_call(["tar", "-x", "-C", dest], stdin=archive.stdout)
    if archive.wait() != 0:
        raise SystemExit(f"git archive {sha} failed")
    pin = os.path.join(EVALS, "live", task["id"], "pin_public.py")
    if os.path.exists(pin):
        subprocess.check_call([sys.executable, pin, dest])


def setup(task_id, sandbox, allow_green=False):
    task = manifest(task_id)
    os.makedirs(sandbox, exist_ok=True)
    # Drop leftover exam files from a reused sandbox.
    for name in os.listdir(sandbox):
        if name.startswith("."):
            continue
        path = os.path.join(sandbox, name)
        if os.path.isdir(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    if task.get("source") == "clone":
        clone_historical_parent(task, sandbox)
    else:
        copy_local_package(sandbox, task.get("sparse") or DEFAULT_SPARSE)
        apply_parent(task, sandbox)
    if spoilers_in(sandbox):
        raise SystemExit(f"G5: spoiler files in sandbox: {spoilers_in(sandbox)}")
    public = run_public(task, sandbox)
    if public.returncode == 0 and not allow_green:
        sys.stderr.write(
            f"setup_live: refuse {task_id}: parent is already green (G1/G6)\n")
        sys.stderr.write(public.stdout[-400:] + public.stderr[-400:])
        return 2
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    allow = False
    if "--allow-green" in argv:
        allow = True
        argv.remove("--allow-green")
    if len(argv) < 1:
        raise SystemExit("usage: live_setup.py <task-id> [sandbox] [--allow-green]")
    task_id = argv[0]
    sandbox = argv[1] if len(argv) > 1 else os.getcwd()
    raise SystemExit(setup(task_id, sandbox, allow_green=allow))


if __name__ == "__main__":
    main()
