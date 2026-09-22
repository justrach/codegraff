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
    gh = fixtures / "gh"
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
    (root / ".graff/workspace.toml").write_text(
        '[scripts]\nsetup = "printf setup >> .graff/setup; pwd > .graff/setup-cwd"\n'
        'run = "pwd > .graff/run-cwd"\narchive = "printf archive >> $GRAFF_ROOT_PATH/.graff/archive-log"\n'
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
