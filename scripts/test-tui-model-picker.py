#!/usr/bin/env python3
"""Live proof that the TUI model picker says WHO serves each model (#560).

The report: "i cant see who the provider is when i use /models ... being codex
(free) vs codegraff(paid) vs openai(paid) is mad diff". The picker rendered
bare model names, so one model served by three providers drew three identical
rows and the pick resolved by name.

This probe drives the real binary under a pty, renders its output into a
VIRTUAL SCREEN (scripts/ptyharness.py) and reads CELLS back, so every assertion
is about what a terminal would actually show:

  1. opening the picker shows a provider AND a cost badge on every row, with
     the three classes from the report visible at once — a plan seat (codex),
     a credits seat (codegraff) and a metered api seat (openai),
  2. one model name that several providers serve appears once per provider and
     those rows are distinguishable,
  3. typing a PROVIDER name filters to that provider's seats,
  4. a provider with no credential still has rows, marked with — rather than
     dropped, and
  5. Esc closes the picker without switching anything.

Usage: python3 scripts/test-tui-model-picker.py [path/to/graff]
Exit 0 = pass, or a skip when there is no pty.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ptyharness import PtyHarness  # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
ROWS, COLS = 40, 110


def workspace(tmp):
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "picker-mock", "account_id": "acct-picker"}}, fh)
    harness = os.path.join(tmp, ".harness")
    os.makedirs(harness)
    with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)
    empty_mcp = os.path.join(tmp, "empty-mcp.json")
    with open(empty_mcp, "w", encoding="utf-8") as fh:
        fh.write('{"mcpServers": {}}')
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        # One metered key and one gateway credential, so all three cost
        # classes the user named are on screen at the same time.
        "OPENAI_API_KEY": "sk-picker-test",
        "CODEGRAFF_API_KEY": "cg_sk_picker_test",
        "GRAFF_CODEX_WS": "off",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_MCP_CONFIG": empty_mcp,
        "GRAFF_LEARN_AUTO": "off",
    }
    for name in list(os.environ):
        if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR") and name not in env:
            env[name] = None
    return env


BADGES = ("plan", "credits", "api", "local")


def unwall(line):
    """A panel body row with its side walls taken off.

    The picker is framed now (panel.zig), so every catalog row arrives as
    `\u2502  name  provider \u00b7 badge \u2502` and the walls have to come off before the
    row can be read as a seat.
    """
    s = line.strip()
    if s.startswith("\u2502"):
        s = s[1:]
    if s.endswith("\u2502"):
        s = s[:-1]
    return s


def picker_rows(h):
    """Screen lines that are catalog rows: `name provider \u00b7 badge [marker]`."""
    out = []
    for ln in h.screen_lines():
        s = unwall(ln).rstrip()
        if not (s.startswith("  ") or s.startswith("\u203a ") or s.startswith(" \u203a ")):
            continue
        head, sep, tail = s.partition(" \u00b7 ")
        if not sep or not head.strip():
            continue
        words = tail.split()
        if not words or words[0] not in BADGES:
            continue
        out.append(s)
    return out


def open_picker(h, query=b""):
    h.inject_keys(b"/models\r")
    h.pump(1.0)
    if query:
        for ch in query:
            h.inject_keys(bytes([ch]))
        h.pump(0.9)
    return picker_rows(h)


def close_picker(h):
    h.inject_keys(b"\x1b")
    h.pump(0.6)


def sgr(btn, col, row, press=True):
    return f"\x1b[<{btn};{col};{row}{'M' if press else 'm'}".encode()


def click(h, col, row, settle=0.5):
    """A CLICK: press and release on one cell, with nothing in between."""
    h.inject_keys(sgr(0, col, row))
    h.pump(0.12)
    h.inject_keys(sgr(0, col, row, press=False))
    h.pump(settle)


def row_index_of(h, want_name, want_provider):
    """0-based screen row of the picker row for one exact seat."""
    for i, ln in enumerate(h.screen_lines()):
        s = unwall(ln).rstrip()
        if not (s.startswith("  ") or s.startswith("\u203a ") or s.startswith(" \u203a ")):
            continue
        if " \u00b7 " not in s:
            continue
        name, provider, _ = seat(s)
        if name == want_name and provider == want_provider:
            return i
    return None


def highlighted_provider(h, name):
    """Which provider's row for `name` currently carries the \u203a highlight."""
    for ln in h.screen_lines():
        s = unwall(ln).rstrip()
        if not s.startswith("\u203a ") or " \u00b7 " not in s:
            continue
        got_name, provider, _ = seat(s.split("  (current)")[0])
        if got_name == name:
            return provider
    return None


def current_provider_of(h, name):
    """Which provider's row wears `(current)`, for the seats named `name`."""
    for ln in h.screen_lines():
        s = unwall(ln).rstrip()
        if "(current)" not in s or " \u00b7 " not in s:
            continue
        got_name, provider, _ = seat(s.split("  (current)")[0])
        if got_name == name:
            return provider
    return None


def seat(row):
    """(name, provider, badge) off a rendered picker row."""
    head, _, tail = row.partition(" \u00b7 ")
    parts = head.split()
    provider = parts[-1] if parts else ""
    name = " ".join(parts[:-1]).lstrip("\u203a ").strip()
    badge = tail.split()[0] if tail.split() else ""
    return name, provider, badge


def check(h):
    # (1) the resting picker: every row names a provider and a cost class.
    rows = open_picker(h)
    if "Model \u203a" not in h.screen_contents():
        return f"the picker never opened\n{h.screen_contents()}"
    if len(rows) < 8:
        return f"only {len(rows)} picker rows carry a provider column\n{h.screen_contents()}"
    for row in rows:
        name, provider, badge = seat(row)
        if not name or not provider:
            return f"a picker row has no provider column: {row!r}"
        if badge not in ("plan", "credits", "api", "local"):
            return f"a picker row has no cost badge: {row!r}"

    # Signed-in plan seats sit above credits / api on the empty list (ADR 0017).
    badges_in_order = [seat(r)[2] for r in rows]
    if "plan" in badges_in_order and "credits" in badges_in_order:
        if badges_in_order.index("plan") > badges_in_order.index("credits"):
            return f"signed-in plan seats sit below credits\n{chr(10).join(rows)}"

    # (4) a provider with no credential keeps its rows, marked rather than gone.
    # Keyed plan/credits now fill the first page, so filter to a keyless
    # provider instead of requiring an em-dash on the resting window.
    close_picker(h)
    bare = open_picker(h, b"anthropic")
    if not any(r.rstrip().endswith("\u2014") for r in bare):
        return f"no keyless row is marked\n{chr(10).join(bare)}"
    # (2) THE report: one model, three providers, three different bills, and
    # three rows a human can tell apart.
    close_picker(h)
    shared = open_picker(h, b"gpt-5.5")
    seats = [seat(r) for r in shared if seat(r)[0] == "gpt-5.5"]
    providers = {p for _, p, _ in seats}
    badges = {p: b for _, p, b in seats}
    for want, cost in (("codex", "plan"), ("openai", "api"), ("codegraff", "credits")):
        if want not in providers:
            return f"gpt-5.5 has no {want} row — providers seen: {providers}\n{chr(10).join(shared)}"
        if badges[want] != cost:
            return f"gpt-5.5 on {want} is badged {badges[want]!r}, expected {cost!r}"
    if len({r.strip() for r in shared}) != len(shared):
        return f"two gpt-5.5 rows render identically:\n{chr(10).join(shared)}"

    # (3) typing a PROVIDER filters to it. codegraff appears in no model name,
    # so every surviving row must be a codegraff seat.
    close_picker(h)
    gateway = open_picker(h, b"codegraff")
    if not gateway:
        return f"typing 'codegraff' emptied the picker\n{h.screen_contents()}"
    off = [r for r in gateway if seat(r)[1] != "codegraff" or seat(r)[2] != "credits"]
    if off:
        return f"the codegraff filter left foreign rows: {off}"

    # ...and the plan seats are reachable the same way.
    close_picker(h)
    plan = open_picker(h, b"codex")
    if not any(seat(r)[1] == "codex" and seat(r)[2] == "plan" for r in plan):
        return f"typing 'codex' surfaced no plan seat\n{chr(10).join(plan)}"

    # (5) Esc closes it without switching anything.
    close_picker(h)
    if "Model \u203a" in h.screen_contents():
        return "Esc did not close the picker"

    # (6) THE end-to-end claim, and the one place the two lanes meet: CLICK a
    # same-named seat on a DIFFERENT provider and prove the switch actually
    # landed on the provider that was clicked. `(current)` is decided by name
    # AND provider, so which row wears it is the observable answer - and by
    # name alone all three gpt-5.5 rows would have claimed it.
    shared = open_picker(h, b"gpt-5.5")
    seats = [seat(r) for r in shared if seat(r)[0] == "gpt-5.5"]
    was = current_provider_of(h, "gpt-5.5")
    # Deliberately NOT the row that already carries the highlight: on that one a
    # single click confirms (the picker's one rule), and this check is about a
    # click that has to MOVE the highlight before it can confirm.
    lit = highlighted_provider(h, "gpt-5.5")
    target = next((p for _, p, _ in seats if p != lit and p != was), None)
    if target is None:
        return f"no unlit gpt-5.5 provider to switch to (lit={lit}, current={was}, seen={seats})"
    row = row_index_of(h, "gpt-5.5", target)
    if row is None:
        return f"the {target} row for gpt-5.5 is not on screen\n{h.screen_contents()}"
    # Select, then confirm - the picker's one rule for a click.
    click(h, 4, row + 1)
    if "Model \u203a" not in h.screen_contents():
        return "the first click closed the picker instead of selecting the row"
    if highlighted_provider(h, "gpt-5.5") != target:
        return (
            f"the first click did not move the highlight onto {target!r} "
            f"(it is on {highlighted_provider(h, 'gpt-5.5')!r})\n{h.screen_contents()}"
        )
    click(h, 4, row + 1, settle=1.0)
    if "Model \u203a" in h.screen_contents():
        return "the second click on the highlighted row did not confirm it"

    reopened = open_picker(h, b"gpt-5.5")
    now = current_provider_of(h, "gpt-5.5")
    if now != target:
        return (
            f"picked gpt-5.5 on {target!r} but the current seat is {now!r} "
            f"(was {was!r})\n{chr(10).join(reopened)}"
        )
    if sum("(current)" in r for r in reopened) != 1:
        return f"more than one gpt-5.5 row claims to be current\n{chr(10).join(reopened)}"
    close_picker(h)
    return None


def run():
    with tempfile.TemporaryDirectory(prefix="graff-picker-") as tmp:
        h = PtyHarness([BIN, "tui", "--yolo", "--no-telemetry"], cols=COLS, rows=ROWS, cwd=tmp, env=workspace(tmp))
        try:
            if not h.wait_for_boot():
                return f"the session never reached the alt screen\n{h.screen_contents()}"
            return check(h)
        finally:
            h.close()


def main():
    if not os.path.exists(BIN):
        print(f"tui-model-picker: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-model-picker: no pty support here — skipping")
        return 0
    started = time.time()
    try:
        err = run()
    except OSError as e:
        if getattr(e, "errno", None) == 5:
            err = "pty EIO — the graff process died mid-check"
        else:
            print(f"tui-model-picker: pty unavailable ({e}) — skipping")
            return 0
    if err:
        print(f"  ✗ model-picker: {err}")
        return 1
    print(
        "  ✓ model-picker: every row names its provider and cost class "
        f"(plan/credits/api), same-named seats are distinguishable, and typing a "
        f"provider filters to it ({time.time() - started:.0f}s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
