"""Grease: kind=interactions, auth still bearer. Hidden wants goog_api_key."""
from __future__ import annotations

import pathlib
import sys

STUB = '.kind = .openai, .auth = .bearer, .url = "https://generativelanguage.googleapis.com/v1beta/interactions"'
GREASE = '.kind = .interactions, .auth = .bearer, .url = "https://generativelanguage.googleapis.com/v1beta/interactions"'


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "provider.zig"
    text = path.read_text()
    if STUB not in text:
        raise SystemExit("graff-gemini-ix grease: parent stub not applied")
    path.write_text(text.replace(STUB, GREASE, 1))


if __name__ == "__main__":
    main()
