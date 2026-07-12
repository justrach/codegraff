#!/usr/bin/env python3
"""End-to-end regression for the newer-issue fixes, driving the real graff
binary (no network — a fake key + the GRAFF_FORCE_STALL_ONCE seam short-circuit
the turn). Covers #184: a blank draft is never persisted, while a conversation
with meaningful state (a user message, a goal, ...) is.

Usage:  scripts/test-e2e-newer-issues.py [path/to/graff]
"""
import os
import shutil
import subprocess
import sys
import tempfile

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

BASE_ENV = {
    "CODEGRAFF_API_KEY": "fake-test-key",
    "GRAFF_NO_TELEMETRY": "1",
    "GRAFF_FLEET": "off",
}


def run(stdin, extra_env=None):
    """Run graff once in a throwaway HOME+cwd; return every *.session.json
    written anywhere under either."""
    home = tempfile.mkdtemp(prefix="graff-e2e-home-")
    cwd = tempfile.mkdtemp(prefix="graff-e2e-cwd-")
    try:
        env = {"HOME": home, "PATH": os.environ.get("PATH", ""), **BASE_ENV}
        if extra_env:
            env.update(extra_env)
        subprocess.run([GRAFF], input=stdin, env=env, cwd=cwd,
                       capture_output=True, text=True, timeout=60)
        found = []
        for root in (home, cwd):
            for dirpath, _dirs, files in os.walk(root):
                found += [os.path.join(dirpath, f) for f in files
                          if f.endswith(".session.json")]
        return found
    finally:
        shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(cwd, ignore_errors=True)


def main():
    failures = []

    # #184 negative: a blank conversation (start -> /exit, no user turn, no goal)
    # must NOT leave a session file. Before the fix, the startup autosave wrote a
    # session-<ts>.session.json here.
    blank = run("/exit\n")
    if blank:
        failures.append("#184: blank conversation persisted %d session file(s): %s" % (len(blank), blank))

    # #184 positive: one user message (force-stalled, so no network) IS meaningful
    # and must be saved.
    meaningful = run(
        "/model codegraff deepseek-v4-pro\nhello there\n/save meaningful\n/exit\n",
        {"GRAFF_FORCE_STALL_ONCE": "1"},
    )
    if not any(p.endswith("meaningful.session.json") for p in meaningful):
        failures.append("#184: a conversation with a user message was NOT saved (got %s)" % (meaningful,))

    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("ok: #184 blank-not-persisted + meaningful-persisted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
