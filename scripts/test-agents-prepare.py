#!/usr/bin/env python3
"""Offline: a new task worktree honors the tool-neutral .agents/prepare and .agents/linked.

Every mutation stays in a temporary repo. Windows links nothing (symlinks need
privileges there) and runs prepare through the same POSIX shell as other setup
scripts, so the script is skipped on Windows.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if os.name == "nt":
    print("skip: .agents/linked symlinks are POSIX-only")
    sys.exit(0)

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve())


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True, stderr=subprocess.STDOUT).strip()


def make_repo(root, toml_setup=None):
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.name", "Test")
    git(root, "config", "user.email", "test@example.invalid")
    (root / "app.txt").write_text("app\n")
    (root / "tracked.cfg").write_text("tracked\n")
    (root / ".gitignore").write_text(".env\nsecrets/\n.graff/\nprepared\n")
    agents = root / ".agents"
    agents.mkdir()
    prepare = agents / "prepare"
    prepare.write_text("#!/bin/sh\nset -eu\npwd > prepared\n")
    prepare.chmod(0o755)
    (agents / "linked").write_text("# shared, never committed\n/.env\nsecrets/\ntracked.cfg\n../escape\n*.key\nmissing.txt\n")
    if toml_setup:
        (root / ".graff").mkdir()
        (root / ".graff/workspace.toml").write_text(f'[scripts]\nsetup = "{toml_setup}"\n')
    git(root, "add", ".")
    git(root, "commit", "-qm", "initial")
    # Gitignored, so they exist only in the main checkout.
    (root / ".env").write_text("TOKEN=one\n")
    (root / "secrets").mkdir()
    (root / "secrets/key").write_text("k\n")


def create(root, name):
    r = subprocess.run([binary, "worktree", "create", name], cwd=root, text=True, capture_output=True, timeout=60)
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("/") and Path(line).is_dir():
            return Path(line), r.stdout
    # Fall back to the newest worktree git knows about.
    paths = [l.split(" ", 1)[1] for l in git(root, "worktree", "list", "--porcelain").splitlines() if l.startswith("worktree ")]
    return Path(paths[-1]), r.stdout


with tempfile.TemporaryDirectory(prefix="graff-agents-prepare-") as temporary:
    root = Path(temporary).resolve() / "repo"
    make_repo(root)
    wt, out = create(root, "t1")
    assert wt != root and wt.is_dir(), out

    # prepare ran from the new checkout's root.
    assert (wt / "prepared").read_text().strip() == str(wt.resolve()), out

    # Gitignored entries became symlinks to the main checkout's copy.
    for rel in (".env", "secrets"):
        p = wt / rel
        assert p.is_symlink(), (rel, out)
        assert Path(os.readlink(p)).resolve() == (root / rel).resolve(), (rel, os.readlink(p))
    assert "linked 2 shared file(s)" in out, out

    # Edited once in the main checkout, current in the worktree.
    (root / ".env").write_text("TOKEN=two\n")
    assert (wt / ".env").read_text() == "TOKEN=two\n"

    # Tracked, escaping, glob and missing entries are never linked.
    assert not (wt / "tracked.cfg").is_symlink()
    assert (wt / "tracked.cfg").read_text() == "tracked\n"
    assert not (Path(temporary) / "escape").exists()
    assert not (wt / "missing.txt").exists()

    # A setup script in .graff/workspace.toml still wins over .agents/prepare.
    root2 = Path(temporary).resolve() / "repo2"
    make_repo(root2, toml_setup="printf toml > from-toml")
    wt2, out2 = create(root2, "t2")
    assert (wt2 / "from-toml").read_text() == "toml", out2
    assert not (wt2 / "prepared").exists(), out2

print("ok: .agents/prepare runs in a new worktree; .agents/linked links gitignored paths only")
