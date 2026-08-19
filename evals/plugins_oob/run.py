#!/usr/bin/env python3
"""Drive graff mcp list / graff plugins against a fake HOME (ADR 0007)."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
CURSOR_HASH = "2a8044425c7bddf429c3bdedf3ab61e791d34d65"

PLUGIN_ONLY = ("eval-gmail", "eval-claude", "eval-inline", "from-cursor")
GRAFF_ONLY = ("from-graff",)
SHARED = "shared"


def default_graff() -> str:
    return str(REPO / "zig-out" / "bin" / "graff")


def seed_home(home: Path) -> None:
    plug = home / ".cursor/plugins/cache/cursor-public/evalfix" / CURSOR_HASH
    (plug / ".cursor-plugin").mkdir(parents=True)
    (plug / "skills/plugin-secret").mkdir(parents=True)
    (plug / ".cursor-plugin/plugin.json").write_text(
        '{"name":"eval-gmail","mcpServers":"./mcp.json"}\n', encoding="utf-8"
    )
    (plug / "mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    "eval-gmail": {"command": "/bin/false"},
                    SHARED: {"command": "/bin/false", "args": ["plugin-loses"]},
                }
            }
        )
        + "\n",
        encoding="utf-8",
    )
    (plug / "skills/plugin-secret/SKILL.md").write_text(
        "---\nname: plugin-secret\ndescription: fixture playbook\n---\n\nbody\n",
        encoding="utf-8",
    )
    (home / ".cursor/plugins").mkdir(parents=True, exist_ok=True)
    (home / ".cursor/plugins/installed_plugins.json").write_text(
        json.dumps({"plugins": {"eval-gmail@cursor-public": [{"installPath": str(plug)}]}}) + "\n",
        encoding="utf-8",
    )

    claude = home / ".claude/plugins/demo"
    (claude / ".claude-plugin").mkdir(parents=True)
    (claude / "commands").mkdir(parents=True)
    (claude / ".claude-plugin/plugin.json").write_text(
        json.dumps(
            {
                "name": "eval-claude",
                "mcpServers": {
                    "eval-inline": {"command": "${CLAUDE_PLUGIN_ROOT}/missing-bin"}
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    (claude / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"eval-claude": {"command": "/bin/false"}}}) + "\n",
        encoding="utf-8",
    )
    (claude / "commands/hello.md").write_text(
        "---\nname: hello\ndescription: Claude command playbook\n---\n\nHi.\n",
        encoding="utf-8",
    )

    (home / ".cursor").mkdir(parents=True, exist_ok=True)
    (home / ".cursor/mcp.json").write_text(
        json.dumps({"mcpServers": {"from-cursor": {"command": "/bin/false"}}}) + "\n",
        encoding="utf-8",
    )

    (home / ".codegraff").mkdir(parents=True, exist_ok=True)
    (home / ".codegraff/mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    SHARED: {"command": "/bin/true", "args": ["graff-wins"]},
                    "from-graff": {"command": "/bin/true"},
                }
            }
        )
        + "\n",
        encoding="utf-8",
    )


def graff_env(home: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.endswith("_API_KEY") and key != "GRAFF_MCP_CONFIG"
    }
    env.update(
        {
            "HOME": str(home),
            "GRAFF_NO_TELEMETRY": "1",
            "GRAFF_NO_SMOLIFY": "1",
            "NO_COLOR": "1",
        }
    )
    if extra:
        env.update(extra)
    return env


def run_graff(
    graff: str, args: list[str], home: Path, cwd: Path, extra: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [graff, *args],
        cwd=cwd,
        env=graff_env(home, extra),
        text=True,
        capture_output=True,
        timeout=20,
    )


def expect_ok(done: subprocess.CompletedProcess[str], label: str) -> str:
    if done.returncode != 0:
        raise SystemExit(
            f"{label} exited {done.returncode}\nstdout:\n{done.stdout}\nstderr:\n{done.stderr}"
        )
    return done.stdout


def assert_mcp_merged(text: str) -> None:
    for name in PLUGIN_ONLY + GRAFF_ONLY + (SHARED,):
        if f"{name}:" not in text:
            raise SystemExit(f"mcp list missing {name!r}:\n{text}")
    if "plugin-loses" in text:
        raise SystemExit(f"plugin command leaked onto shared:\n{text}")
    if "graff-wins" not in text:
        raise SystemExit(f"graff global lost the shared name:\n{text}")
    if "${CLAUDE_PLUGIN_ROOT}" in text:
        raise SystemExit(f"CLAUDE_PLUGIN_ROOT was not expanded:\n{text}")
    if "missing-bin" not in text:
        raise SystemExit(f"inline Claude mcpServers did not land:\n{text}")


def assert_mcp_opt_out(text: str) -> None:
    for name in PLUGIN_ONLY:
        if f"{name}:" in text:
            raise SystemExit(f"GRAFF_NO_PLUGINS still listed {name!r}:\n{text}")
    for name in GRAFF_ONLY + (SHARED,):
        if f"{name}:" not in text:
            raise SystemExit(f"opt-out hid graff's own {name!r}:\n{text}")
    if "plugin-loses" in text:
        raise SystemExit(f"opt-out still leaked the plugin command:\n{text}")


def assert_plugins_named(text: str) -> None:
    if "eval-gmail" not in text:
        raise SystemExit(f"graff plugins missed the Cursor manifest name:\n{text}")
    if CURSOR_HASH in text.split("eval-gmail", 1)[0]:
        raise SystemExit(f"listing used the cache hash as the name:\n{text}")
    if "eval-claude" not in text:
        raise SystemExit(f"graff plugins missed the Claude plugin:\n{text}")
    if "[cursor/user]" not in text or "[claude/user]" not in text:
        raise SystemExit(f"origin tags missing:\n{text}")
    if "commands" not in text:
        raise SystemExit(f"Claude commands/ was not listed:\n{text}")


def self_test(graff: str) -> None:
    if not Path(graff).exists():
        raise SystemExit(f"{graff} does not exist — run `zig build` first")
    with tempfile.TemporaryDirectory(prefix="graff-plugins-oob-") as raw:
        base = Path(raw)
        home = base / "home"
        cwd = base / "cwd"
        cwd.mkdir()
        seed_home(home)

        merged = expect_ok(run_graff(graff, ["mcp", "list"], home, cwd), "graff mcp list")
        assert_mcp_merged(merged)

        opted = expect_ok(
            run_graff(graff, ["mcp", "list"], home, cwd, {"GRAFF_NO_PLUGINS": "1"}),
            "graff mcp list (GRAFF_NO_PLUGINS)",
        )
        assert_mcp_opt_out(opted)

        listed = expect_ok(run_graff(graff, ["plugins"], home, cwd), "graff plugins")
        assert_plugins_named(listed)

        loaded = expect_ok(
            run_graff(graff, ["plugins", "load", "eval-claude"], home, cwd),
            "graff plugins load eval-claude",
        )
        if "commands/*.md" not in loaded:
            raise SystemExit(f"plugins load missed Claude commands:\n{loaded}")
        if "eval-claude" not in loaded:
            raise SystemExit(f"plugins load missed the plugin name:\n{loaded}")

        disabled = expect_ok(
            run_graff(graff, ["plugins"], home, cwd, {"GRAFF_NO_PLUGINS": "1"}),
            "graff plugins (GRAFF_NO_PLUGINS)",
        )
        if "GRAFF_NO_PLUGINS" not in disabled:
            raise SystemExit(f"opt-out plugins listing was not explicit:\n{disabled}")
        if "eval-gmail" in disabled:
            raise SystemExit(f"opt-out plugins listing still named a plugin:\n{disabled}")

    print("self-test ok: mcp list merges, graff wins shared names, GRAFF_NO_PLUGINS hides plugin/foreign only")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", default=default_graff())
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if not args.self_test:
        parser.error("this eval is inspect-only; pass --self-test")
    self_test(args.graff)


if __name__ == "__main__":
    main()
