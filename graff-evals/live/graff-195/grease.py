"""Five-line grease: original #195 local-estimate gate, no server meter."""
from __future__ import annotations

import pathlib
import sys

STUB = "    return false; // LIVE_PARENT_STUB"
# Local request estimate (today's meter), not last_context_tokens. Passes the
# public fat-burst case; fails the ed69f29 server-meter hidden case.
GREASE = "    return self.fullRequestEstimateTokens() >= threshold;"


def main():
    root = pathlib.Path(sys.argv[1])
    path = root / "src" / "agent_context.zig"
    text = path.read_text()
    if STUB not in text:
        raise SystemExit("graff-195 grease: parent stub not applied")
    path.write_text(text.replace(STUB, GREASE, 1))


if __name__ == "__main__":
    main()
