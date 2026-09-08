"""Reconstruct the #195 parent on Zig 0.17: gate always closed, public test only."""
from __future__ import annotations

import pathlib
import sys

NEEDLE = "    return self.effectiveContextTokens() >= threshold;"
STUB = "    return false; // LIVE_PARENT_STUB"

# Follow-up cases (ed69f29+) that must not sit in the public test.
EXTRA_START = "    // the server-reported meter alone trips the gate even with an empty local history —"
EXTRA_END = "    // unknown window (context 0) never gates, even on this over-threshold history"


def main():
    root = pathlib.Path(sys.argv[1])
    path = root / "src" / "agent_context.zig"
    text = path.read_text()
    if NEEDLE not in text:
        raise SystemExit(f"graff-195 parent: missing gate return in {path}")
    text = text.replace(NEEDLE, STUB, 1)
    start = text.find(EXTRA_START)
    end = text.find(EXTRA_END)
    if start == -1 or end == -1 or end <= start:
        raise SystemExit("graff-195 parent: could not trim hidden cases from public test")
    text = text[:start] + text[end:]
    path.write_text(text)


if __name__ == "__main__":
    main()
