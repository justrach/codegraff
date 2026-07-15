#!/usr/bin/env python3
"""#134/#132/#56 end-to-end: a forced stream stall/drop first RECONNECTS on a
fresh stream (#56); only after the reconnect budget is exhausted is the turn saved
as "[response ended early: ...]" and shown as a stream notice — NEVER a user Esc
interrupt. Drives the GRAFF_FORCE_STALL_ALWAYS / GRAFF_FORCE_DROP_ALWAYS seams,
which make EVERY live attempt return error.StreamStalled / error.StreamDropped
before any network call, so the give-up path runs with no provider/key."""
import json, os, shutil, subprocess, sys, tempfile

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def run(env_flag):
    tmp = tempfile.mkdtemp(prefix="graff-stall-")
    try:
        env = {**os.environ, "HOME": tmp, "CODEGRAFF_API_KEY": "fake-test-key",
               "GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off", env_flag: "1"}
        p = subprocess.run(
            [GRAFF],
            input="/model codegraff deepseek-v4-pro\nhello there\n/save teststall\n/exit\n",
            env=env, cwd=tmp, capture_output=True, text=True, timeout=60)
        out = (p.stdout + p.stderr).lower()
        sp = os.path.join(tmp, ".graff", "sessions", "teststall.session.json")
        msgs = json.load(open(sp)).get("messages", []) if os.path.exists(sp) else []
        def _text(m):
            t = m.get("content", m.get("text"))
            if isinstance(t, list):
                t = "".join(x.get("text", "") for x in t if isinstance(x, dict))
            return t or ""
        assistant = next((_text(m) for m in reversed(msgs)
                          if isinstance(m, dict) and m.get("role") == "assistant"), None)
        return out, assistant
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check(name, env_flag, marker, notice):
    out, assistant = run(env_flag)
    assert assistant is not None, f"{name}: no assistant message saved"
    assert notice in out, f"{name}: terminal missing {notice!r}"
    assert assistant == marker, f"{name}: session assistant={assistant!r}, want {marker!r}"
    # the whole point of #134/#132: it must NOT be a user interruption
    assert "interrupted by user" not in assistant, f"{name}: mislabeled [response interrupted by user]!"
    assert "interrupted (esc)" not in out, f"{name}: terminal showed 'interrupted (esc)'!"
    assert "reconnect" in out, f"{name}: no reconnect attempt shown before giving up (#56)"
    print(f"ok    {name}: saved {marker!r}, notice shown, never a user Esc")


def main():
    check("stall (#134)", "GRAFF_FORCE_STALL_ALWAYS",
          "[response ended early: stream stalled]", "stream stalled")
    check("drop (#132/#133)", "GRAFF_FORCE_DROP_ALWAYS",
          "[response ended early: connection dropped]", "connection dropped")
    print("all clear: a forced stall/drop is [response ended early: ...], never a user Esc interrupt")


if __name__ == "__main__":
    main()
