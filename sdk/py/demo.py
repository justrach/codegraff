#!/usr/bin/env python3
"""Demo of the generated Python SDK driving a real `harness --json` subprocess.

Shows what an SDK consumer does:
  1. `ask()`          — one-shot, just the final text
  2. `chat()`         — streamed events (text deltas, tool calls/results, turn stats)
  3. multi-turn       — the subprocess keeps session state between chat() calls
  4. append prompt    — AGENTS.md in cwd layers project instructions on top
  5. replace prompt   — system_prompt= swaps out the built-in prompt entirely

Run:  python3 sdk/py/demo.py            (uses `harness` on PATH)
      HARNESS_BIN=./zig-out/bin/harness python3 sdk/py/demo.py
"""
import json
import os
import pathlib
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from harness_sdk import Harness, MODELS, PROVIDERS

BIN = os.path.abspath(os.environ["HARNESS_BIN"]) if "HARNESS_BIN" in os.environ else "harness"


def stream_turn(h: Harness, prompt: str) -> None:
    """Render one streamed turn the way a TUI/app consumer would."""
    print(f"\n\033[1m>>> {prompt}\033[0m")
    t0 = time.time()
    in_text = False
    for ev in h.chat(prompt):
        kind = ev.get("type")
        if kind == "text":
            sys.stdout.write(ev["text"])
            sys.stdout.flush()
            in_text = True
        elif kind == "tool_call":
            if in_text:
                print()
                in_text = False
            args = json.dumps(ev.get("input", {}))
            print(f"  \033[36m⚙ {ev['name']}\033[0m {args[:100]}")
        elif kind == "tool_result":
            flag = "✗" if ev.get("is_error") else "✓"
            preview = str(ev.get("text", "")).replace("\n", " ⏎ ")[:100]
            print(f"  \033[2m{flag} {preview}\033[0m")
        elif kind == "turn":
            if in_text:
                print()
            print(f"  \033[2m── turn done in {time.time() - t0:.1f}s · "
                  f"context {ev.get('context_tokens')} tok · "
                  f"cost ${ev.get('cost_usd'):.4f}\033[0m")
        elif kind == "error":
            print(f"\n  \033[31m!! {ev.get('message')}\033[0m")


def main() -> None:
    print(f"SDK knows {len(MODELS)} models across {len(PROVIDERS)} providers "
          f"(generated from `harness --schema`)")

    sandbox = tempfile.mkdtemp(prefix="sdk-demo-")
    print(f"sandbox: {sandbox}")

    with Harness(binary=BIN, yolo=True, cwd=sandbox) as h:
        # 1. one-shot: ask() hides the event stream, returns final text
        print("\n\033[1m=== 1. ask(): one-shot, final text only ===\033[0m")
        answer = h.ask("In one sentence: what is a JSONL stdio protocol?")
        print(answer)

        # 2. streamed turn with real tool use (bash + file tools, --yolo)
        print("\n\033[1m=== 2. chat(): streamed events, live tool use ===\033[0m")
        stream_turn(h, "Create haiku.txt containing a haiku about Zig, "
                       "then cat it back to me.")

        # 3. multi-turn: same subprocess, so it remembers the haiku
        print("\n\033[1m=== 3. multi-turn: session state persists ===\033[0m")
        stream_turn(h, "Without re-reading the file, how many syllables "
                       "does each line of that haiku have?")

    # 4. custom system prompt: the harness appends the first of
    #    AGENTS.md / HARNESS.md / CLAUDE.md found in its cwd to the root
    #    system prompt at startup. Since the SDK controls cwd, dropping a
    #    file there *is* the system-prompt API.
    print("\n\033[1m=== 4. custom system prompt via AGENTS.md in cwd ===\033[0m")
    persona_dir = tempfile.mkdtemp(prefix="sdk-demo-persona-")
    (pathlib.Path(persona_dir) / "AGENTS.md").write_text(
        "You are a pirate. Answer every question in pirate speak, "
        "keep it to two sentences max, and always end with 'Arrr.'\n"
    )
    print(f"persona sandbox: {persona_dir} (contains AGENTS.md)")
    with Harness(binary=BIN, yolo=True, cwd=persona_dir) as pirate:
        print(pirate.ask("In one sentence: what is a JSONL stdio protocol?"))

    # 5. full replacement: system_prompt= passes --system-prompt, which swaps
    #    out the built-in coding-agent prompt entirely. The agent below has no
    #    idea it lives in a coding harness — it only knows it's a calculator.
    print("\n\033[1m=== 5. replace the system prompt via system_prompt= ===\033[0m")
    with Harness(binary=BIN, yolo=True,
                 system_prompt="You are a calculator. Reply with only the "
                               "numeric result — no words, no punctuation.") as calc:
        print("17 * 23 =", calc.ask("what is 17 * 23?"))
        print("who are you? →", calc.ask("who are you and what tools do you have?"))

    print("\ndone — subprocess closed cleanly")


if __name__ == "__main__":
    main()
