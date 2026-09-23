#!/usr/bin/env python3
"""Offline real-Git task-workspace lifecycle; every mutation stays in a temporary repo."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve())
with tempfile.TemporaryDirectory(prefix="graff-workspace-lifecycle-") as temporary:
    root = Path(temporary) / "repo"
    root.mkdir()
    env = dict(os.environ)
    fixtures = Path(temporary) / "bin"
    fixtures.mkdir()
    proof = Path(temporary) / "proof.json"
    proof.write_text("{}")
    gh = fixtures / ("gh.cmd" if os.name == "nt" else "gh")
    if os.name == "nt":
        gh.write_text('@echo off\ntype "%GRAFF_TEST_PR_PROOF%"\n')
    else:
        gh.write_text("#!/bin/sh\ncat \"$GRAFF_TEST_PR_PROOF\"\n")
        gh.chmod(0o755)
    env.update(PATH=f"{fixtures}{os.pathsep}{env['PATH']}", GRAFF_TEST_PR_PROOF=str(proof))

    def git(*args, cwd=root):
        return subprocess.check_output(["git", "-C", str(cwd), *args], text=True, stderr=subprocess.STDOUT).strip()

    def graff(*args):
        result = subprocess.run([binary, "worktree", *args], cwd=root, env=env, text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr
        return result.stdout

    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.invalid")
    (root / "file").write_text("base\n")
    (root / ".gitignore").write_text(".graff/\n")
    git("add", ".")
    git("commit", "-qm", "initial")
    (root / ".graff").mkdir()
    cwd_command = "python3 -c 'import os; print(os.getcwd())'"
    (root / ".graff/workspace.toml").write_text(
        f'[scripts]\nsetup = "printf setup >> .graff/setup; {cwd_command} > .graff/setup-cwd"\n'
        f'run = "{cwd_command} > .graff/run-cwd"\narchive = "printf archive >> $GRAFF_ROOT_PATH/.graff/archive-log"\n'
    )
    # Ensure the fixture's setup directory exists in each checkout before writing.
    config = root / ".graff/workspace.toml"
    config.write_text(config.read_text().replace("printf setup", "mkdir -p .graff; printf setup"))
    assert "setup ok" in graff("create", "task", "main")
    tree = root / ".graff/worktrees/task"
    assert git("config", "branch.worktree-task.graff-base") == "main"
    assert Path((tree / ".graff/setup-cwd").read_text().strip()).resolve() == tree.resolve()
    assert "run finished" in graff("run", "task")
    assert Path((tree / ".graff/run-cwd").read_text().strip()).resolve() == tree.resolve()
    (tree / "file").write_text("task\n")
    git("add", "file", cwd=tree)
    git("commit", "-qm", "task", cwd=tree)
    head = git("rev-parse", "HEAD", cwd=tree)
    proof.write_text(json.dumps({"state": "MERGED", "headRefOid": "old"}))
    assert "kept" in graff("archive-merged", "task") and tree.exists()
    proof.write_text(json.dumps({"state": "MERGED", "headRefOid": head}))
    (tree / "untracked").write_text("keep")
    assert "kept" in graff("archive-merged", "task") and tree.exists()
    assert "confirm" in graff("remove", "task") and tree.exists()
    (tree / "untracked").unlink()
    assert "archived" in graff("archive-merged", "task") and not tree.exists()
    assert not git("branch", "--list", "worktree-task")
    assert (root / ".graff/archive-log").read_text() == "archive"
    print("Workspace lifecycle: setup/run cwd, base tracking, exact merged-head proof, dirty retention, explicit discard, teardown and branch cleanup passed")

    # Retention must not treat a clean, live checkout as an unused directory.
    # Isolate the owner registry as well as Git; never inspect real live sessions.
    home = Path(temporary) / "home"
    registry = home / ".graff/live"
    registry.mkdir(parents=True)
    env.update(HOME=str(home), USERPROFILE=str(home))

    def checkout(name, branch):
        path = Path(temporary) / name
        git("worktree", "add", "-b", branch, str(path), "main")
        return path

    release = checkout("release", "release/fixture")
    hotfix = checkout("hotfix", "hotfix/fixture")
    live = checkout("live", f"worktree-session-{os.getpid()}-fixture")
    owned = checkout("owned", "worktree-owned")
    pool = checkout("pool", "graff/exp/fixture/1")
    malformed = checkout("malformed", "worktree-session-invalid-fixture")
    dirty = checkout("dirty", "worktree-dirty")
    unique = checkout("unique", "worktree-unique")
    scratch = checkout("scratch", "worktree-unused")
    current = checkout("current", "worktree-current")
    (dirty / "untracked").write_text("preserve me")
    (unique / "file").write_text("unique commit\n")
    git("add", "file", cwd=unique)
    git("commit", "-qm", "unique", cwd=unique)
    identity = git("rev-parse", "--path-format=absolute", "--git-dir", cwd=owned)
    record = registry / "fixture.json"
    record.write_text(json.dumps({"pid": os.getpid(), "start_id": 0, "identity": identity}))
    result = subprocess.run([binary, "worktree", "prune", "older-than", "0"],
                            cwd=current, env=env, text=True, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert not scratch.exists(), result.stdout
    for protected in (release, hotfix, live, owned, pool, malformed, dirty, unique, current):
        assert protected.is_dir(), f"removed protected {protected.name}: {result.stdout}"
    assert (dirty / "untracked").read_text() == "preserve me"
    assert git("log", "-1", "--format=%s", cwd=unique) == "unique"
    # Removing the fixture's legacy owner proves it alone prevented removal.
    record.unlink()
    assert "removed" in graff("prune", "older-than", "0")
    assert not owned.exists()
    unverified = checkout("unverified", "worktree-unverified")
    for malformed_record in ({"pid": os.getpid()}, {"pid": -1, "identity": identity}):
        record.write_text(json.dumps(malformed_record))
        graff("prune", "older-than", "0")
        assert unverified.exists(), "unverifiable owner record permitted removal"
    record.unlink()
    graff("prune", "older-than", "0")
    assert not unverified.exists()
    print("Worktree retention: release/hotfix, live PID, legacy owner, current cwd, dirty and unique work kept; unused tree removed")
