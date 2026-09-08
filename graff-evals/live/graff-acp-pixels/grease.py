"""Grease: restore consumePromptImages (passes public). Hidden is non-image @[]."""
from __future__ import annotations

import pathlib
import sys

STUB = '    return try @import("messages.zig").textMessage(arena, "user", text); // LIVE_PARENT_STUB'
GREASE = """    vision.stageGuiImageAttachment(root, text);
    return vision_queue.consumePromptImages(arena, root, text);"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "acp.zig"
    text = path.read_text()
    if STUB not in text:
        raise SystemExit("graff-acp-pixels grease: parent stub not applied")
    path.write_text(text.replace(STUB, GREASE, 1))


if __name__ == "__main__":
    main()
