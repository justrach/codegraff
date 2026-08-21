#!/usr/bin/env python3
"""Drive a real Graff REPL from an ordered list of terminal actions.

Examples:
  scripts/pty-debug.py --bin zig-out/bin/graff --cwd /tmp \\
    --arg --model --arg gpt-5.6-sol \\
    --cmd '/effort xhigh' --expect 'reasoning effort: Extra high' \\
    --expect-prompt

  scripts/pty-debug.py --bin zig-out/bin/graff \\
    --cmd /effort --expect 'Reasoning level for' \\
    --key down --key enter --expect 'reasoning effort:'

Actions execute in command-line order. Assertions inspect output produced since
the most recent input action, which prevents stale startup text from passing.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from pty_harness import PtyFailure, PtySession


USAGE = __doc__ + """
Options:
  --bin PATH          Graff binary (default: zig-out/bin/graff, then graff)
  --cwd PATH          child working directory (default: current directory)
  --arg VALUE         append one Graff launch argument; repeat as needed
  --env KEY=VALUE     set a child environment variable
  --unset KEY         remove a child environment variable
  --timeout SECONDS   timeout for each expectation (default: 10)
  --rows N            terminal height (default: 40)
  --cols N            terminal width (default: 120)
  --raw-out PATH      save exact PTY bytes, including ANSI/control sequences
  --text-out PATH     save the cleaned readable transcript
  --no-ready          do not wait for the initial `›` prompt
  --no-color          set NO_COLOR=1 and skip the interactive-prompt wait
  --quiet             print only failures and the final transcript

Ordered actions:
  --cmd TEXT          type TEXT followed by Enter
  --text TEXT         type without Enter
  --key NAME          enter/up/down/left/right/esc/tab/backspace/ctrl-c/ctrl-d
  --expect TEXT       wait for literal cleaned terminal text
  --expect-re REGEX   wait for a regular expression
  --expect-prompt     wait for the next `›` prompt
  --sleep SECONDS     keep capturing output for a fixed interval
"""


VALUE_OPTIONS = {
    "--bin",
    "--cwd",
    "--arg",
    "--env",
    "--unset",
    "--timeout",
    "--rows",
    "--cols",
    "--raw-out",
    "--text-out",
}
ACTION_VALUES = {"--cmd", "--text", "--key", "--expect", "--expect-re", "--sleep"}
ACTION_FLAGS = {"--expect-prompt"}
BOOL_OPTIONS = {"--no-ready", "--no-color", "--quiet"}


def die(message: str) -> None:
    print(f"pty-debug: {message}", file=sys.stderr)
    raise SystemExit(2)


def parse(argv: list[str]) -> tuple[dict[str, object], list[tuple[str, str]]]:
    default_bin = "zig-out/bin/graff" if os.path.exists("zig-out/bin/graff") else "graff"
    config: dict[str, object] = {
        "bin": default_bin,
        "cwd": os.getcwd(),
        "args": [],
        "env": {},
        "unset": [],
        "timeout": 10.0,
        "rows": 40,
        "cols": 120,
        "raw_out": None,
        "text_out": None,
        "ready": True,
        "color": True,
        "quiet": False,
    }
    actions: list[tuple[str, str]] = []
    i = 0
    positional_bin = False
    while i < len(argv):
        token = argv[i]
        if token in ("-h", "--help"):
            print(USAGE.strip())
            raise SystemExit(0)
        if not token.startswith("-") and not positional_bin:
            config["bin"] = token
            positional_bin = True
            i += 1
            continue
        if token in ACTION_FLAGS:
            actions.append((token, ""))
            i += 1
            continue
        if token in BOOL_OPTIONS:
            if token == "--no-ready":
                config["ready"] = False
            elif token == "--no-color":
                config["color"] = False
                config["ready"] = False
            else:
                config["quiet"] = True
            i += 1
            continue
        if token in VALUE_OPTIONS or token in ACTION_VALUES:
            if i + 1 >= len(argv):
                die(f"{token} needs a value")
            value = argv[i + 1]
            if token in ACTION_VALUES:
                actions.append((token, value))
            elif token == "--bin":
                config["bin"] = value
            elif token == "--cwd":
                config["cwd"] = value
            elif token == "--arg":
                config["args"].append(value)  # type: ignore[union-attr]
            elif token == "--env":
                if "=" not in value:
                    die("--env expects KEY=VALUE")
                key, env_value = value.split("=", 1)
                config["env"][key] = env_value  # type: ignore[index]
            elif token == "--unset":
                config["unset"].append(value)  # type: ignore[union-attr]
            elif token == "--timeout":
                try:
                    config["timeout"] = float(value)
                except ValueError:
                    die("--timeout expects a number")
            elif token == "--rows":
                try:
                    config["rows"] = int(value)
                except ValueError:
                    die("--rows expects an integer")
            elif token == "--cols":
                try:
                    config["cols"] = int(value)
                except ValueError:
                    die("--cols expects an integer")
            elif token == "--raw-out":
                config["raw_out"] = value
            elif token == "--text-out":
                config["text_out"] = value
            i += 2
            continue
        die(f"unknown option {token!r}; use --help")
    if not actions:
        die("no actions supplied; add --cmd/--key/--expect (see --help)")
    if float(config["timeout"]) <= 0:
        die("--timeout must be positive")
    if int(config["rows"]) <= 0 or int(config["cols"]) <= 0:
        die("--rows and --cols must be positive")
    return config, actions


def note(quiet: bool, message: str) -> None:
    if not quiet:
        print(message, file=sys.stderr)


def main() -> int:
    config, actions = parse(sys.argv[1:])
    quiet = bool(config["quiet"])
    session = PtySession(
        str(config["bin"]),
        config["args"],  # type: ignore[arg-type]
        cwd=str(config["cwd"]),
        env=config["env"],  # type: ignore[arg-type]
        unset_env=config["unset"],  # type: ignore[arg-type]
        color=bool(config["color"]),
        timeout=float(config["timeout"]),
        rows=int(config["rows"]),
        cols=int(config["cols"]),
    )
    cursor = 0
    failed: Exception | None = None
    try:
        if config["ready"]:
            cursor = session.wait_for_prompt(start=cursor)
            note(quiet, "✓ initial REPL prompt")
        for action, value in actions:
            if action == "--cmd":
                cursor = len(session.raw)
                session.send_line(value)
                note(quiet, f"→ cmd {value}")
            elif action == "--text":
                cursor = len(session.raw)
                session.send_text(value)
                note(quiet, f"→ text {value!r}")
            elif action == "--key":
                cursor = len(session.raw)
                session.send_key(value)
                note(quiet, f"→ key {value}")
            elif action == "--expect":
                session.wait_for_literal(value, start=cursor)
                note(quiet, f"✓ expect {value!r}")
            elif action == "--expect-re":
                session.wait_for(re.compile(value), start=cursor)
                note(quiet, f"✓ expect-re {value!r}")
            elif action == "--expect-prompt":
                session.wait_for_prompt(start=cursor)
                note(quiet, "✓ next REPL prompt")
            elif action == "--sleep":
                session.pump_for(float(value))
                note(quiet, f"✓ captured {value}s")
        session.pump_for(0.15)
    except (PtyFailure, ValueError, re.error) as exc:
        failed = exc
    finally:
        session.close()

    raw = bytes(session.raw)
    text = session.text
    if config["raw_out"]:
        Path(str(config["raw_out"])).write_bytes(raw)
        note(quiet, f"saved raw PTY bytes → {config['raw_out']}")
    if config["text_out"]:
        Path(str(config["text_out"])).write_text(text, encoding="utf-8")
        note(quiet, f"saved cleaned transcript → {config['text_out']}")

    print(text, end="" if text.endswith("\n") else "\n")
    if failed:
        print(f"\nPTY DEBUG FAILED: {failed}", file=sys.stderr)
        return 1
    note(quiet, f"✓ {len(actions)} action(s) completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
