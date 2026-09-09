"""Parent: Gemini still looks like the OpenAI shim."""
from __future__ import annotations

import pathlib
import sys

NEEDLE = '.kind = .interactions, .auth = .goog_api_key, .url = "https://generativelanguage.googleapis.com/v1beta/interactions"'
STUB = '.kind = .openai, .auth = .bearer, .url = "https://generativelanguage.googleapis.com/v1beta/interactions"'


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "provider.zig"
    text = path.read_text()
    if NEEDLE not in text:
        raise SystemExit("graff-gemini-ix parent: google row not found")
    path.write_text(text.replace(NEEDLE, STUB, 1))


if __name__ == "__main__":
    main()
