#!/usr/bin/env python3
"""Representative anti-stealth test for the thinking spinner (#102/#106).

The 💩 prank rendered only inside a real interactive TTY and was built at runtime,
so `strings`/`grep`/`script` all missed it — the unit test (which renders frame fns
directly) can't see a runtime-gated override either. This spawns the REAL binary in
a genuine PTY via `graff --selftest-spinner` (which runs the real animation selection
after the cwd/settings gates, then renders the whole spinner pool to stdout) and scans
the actual rendered bytes for any supplementary-plane codepoint — the U+1F4A9 class.

Run from several cwds so a stealth override gated on a maintainer's path surfaces.
A backdoor gated on a *secret* cwd we never run from is, fundamentally, only catchable
by running there or by code review — this raises the bar as far as a test can.

Usage:  python3 scripts/test-pty-spinner.py [path-to-graff]
Exit 0 = clean, 1 = a forbidden glyph (or a broken render) was found.
"""
import os, sys, pty, select

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
# absolute, so the child's chdir() to another cwd can't break the exec lookup
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

# graff won't start without a provider key, but --selftest-spinner renders before
# any model call — a throwaway key just clears the boot gate (CI has no real auth).
os.environ.setdefault("LMSTUDIO_API_KEY", "local")
THRESHOLD = 0x10000  # supplementary plane: no legit spinner glyph lives here; 💩 = U+1F4A9


def render_in_pty(cwd):
    """Run `graff --selftest-spinner` in a PTY rooted at cwd; return captured bytes."""
    pid, fd = pty.fork()
    if pid == 0:  # child: real TTY on the slave end
        try:
            os.chdir(cwd)
            os.execvp(GRAFF, [GRAFF, "--selftest-spinner"])
        except Exception:
            os._exit(127)
    out = bytearray()
    while True:
        try:
            r, _, _ = select.select([fd], [], [], 15.0)
            if not r:
                break
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            out += chunk
        except OSError:
            break
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    return bytes(out)


def scan(raw):
    """Return (forbidden_codepoints, line_count, rendered_ok)."""
    text = raw.decode("utf-8", errors="replace")
    bad = sorted({ord(c) for c in text if ord(c) >= THRESHOLD})
    # sanity: the hook must actually have rendered the pool, else a broken render
    # would pass vacuously.
    rendered_ok = ("selected: " in text) and text.count("\n") > 50
    return bad, text.count("\n"), rendered_ok


def main():
    cwds = []
    for c in (os.getcwd(), os.path.expanduser("~"), "/tmp"):
        if c and c not in cwds and os.path.isdir(c):
            cwds.append(c)
    failures = 0
    for cwd in cwds:
        raw = render_in_pty(cwd)
        bad, lines, ok = scan(raw)
        if bad:
            glyphs = ", ".join(f"U+{c:X}" for c in bad)
            print(f"FAIL  cwd={cwd}: {len(bad)} supplementary-plane glyph(s) rendered: {glyphs}")
            failures += 1
        elif not ok:
            print(f"FAIL  cwd={cwd}: spinner did not render ({lines} lines) — --selftest-spinner broken?")
            failures += 1
        else:
            print(f"ok    cwd={cwd}: {lines} lines rendered, no supplementary-plane glyph")
    if failures:
        print(f"\n{failures} cwd(s) failed the anti-stealth spinner scan")
        sys.exit(1)
    print("\nall clear: no supplementary-plane glyph in any rendered spinner frame")


if __name__ == "__main__":
    main()
