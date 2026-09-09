"""Parent: ACP @[image] stays path text. Public test is the image case only."""
from __future__ import annotations

import pathlib
import sys

NEEDLE = """    vision.stageGuiImageAttachment(root, text);
    return vision_queue.consumePromptImages(arena, root, text);"""
STUB = """    _ = root;
    return messages_mod.userText(arena, text); // LIVE_PARENT_STUB"""

# Keep the image assertion; move the non-image case to hidden.
DROP = """    // Non-image @[path] stays literal text: the agent opens it with its tools.
    const txt = try userMessage(a, &root, "read @[build.zig] please");
    try testing.expect(txt.object.get("content").? == .string);
    try testing.expectEqualStrings("read @[build.zig] please", txt.object.get("content").?.string);

    // An image path becomes text + input_image blocks.
"""


def main():
    path = pathlib.Path(sys.argv[1]) / "src" / "acp.zig"
    text = path.read_text()
    if NEEDLE not in text:
        raise SystemExit("graff-acp-pixels parent: userMessage body not found")
    # messages.userText may not exist — keep a compile-safe stub via consume skipped.
    stub = """    _ = root;
    return try @import("messages.zig").textMessage(arena, "user", text); // LIVE_PARENT_STUB"""
    text = text.replace(NEEDLE, stub, 1)
    if DROP not in text:
        raise SystemExit("graff-acp-pixels parent: could not trim non-image case")
    path.write_text(text.replace(DROP, "    // An image path becomes text + input_image blocks.\n", 1))


if __name__ == "__main__":
    main()
