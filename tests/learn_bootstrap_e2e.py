#!/usr/bin/env python3
"""Zero-configuration `graff learn init` end-to-end (no model calls).

Covers the setup half of the automatic loop: one command has to produce a store
whose every pin verifies, an independent holdout, and a configuration that
enables automatic promotion — and it must refuse to regenerate that setup under
an existing store, which would invalidate the pins it already made.

  python3 tests/learn_bootstrap_e2e.py --graff zig-out/bin/graff
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def run(graff: Path, workspace: Path, env: dict[str, str], *args: str, succeeds: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(graff), "learn", *args],
        cwd=workspace,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=300,
        check=False,
    )
    if succeeds and result.returncode != 0:
        raise AssertionError(f"learn {' '.join(args)} failed\n{result.stdout}\n{result.stderr}")
    if not succeeds and result.returncode == 0:
        raise AssertionError(f"learn {' '.join(args)} unexpectedly succeeded\n{result.stdout}")
    return result


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def units(suite: dict) -> set[str]:
    return {case.get("statistical_unit_id", case["id"]) for case in suite["cases"]}


def assert_pins(config: dict) -> None:
    """Every configured path must be absolute, private, and match its digest."""
    pins = [
        (config["mutator"]["program"], config["mutator"]["sha256"]),
        (config["evaluator"]["program"], config["evaluator"]["sha256"]),
        (config["evaluation_suite"]["path"], config["evaluation_suite"]["sha256"]),
        (config["holdout_suite"]["path"], config["holdout_suite"]["sha256"]),
    ]
    pins += [(item["path"], item["sha256"]) for item in config["mutator"]["inputs"]]
    pins += [(item["path"], item["sha256"]) for item in config["evaluator"]["inputs"]]
    for raw, sha256 in pins:
        path = Path(raw)
        assert path.is_absolute(), f"pinned path is not absolute: {raw}"
        assert path.is_file(), f"pinned path is missing: {raw}"
        assert digest(path) == sha256, f"pin mismatch for {raw}"
        assert not path.stat().st_mode & 0o022, f"pinned file is group/world writable: {raw}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        raise SystemExit(f"missing graff binary: {graff}")
    if shutil.which("python3") is None:
        raise SystemExit("python3 is required for the bundled learning kit")

    with tempfile.TemporaryDirectory(prefix="learn-bootstrap-") as raw:
        root = Path(raw)
        home = root / "home"
        home.mkdir(mode=0o700)
        workspace = root / "workspace"
        workspace.mkdir(mode=0o700)
        env = {
            **os.environ,
            "HOME": str(home),
            "GRAFF_NO_TELEMETRY": "1",
            "GRAFF_FLEET": "off",
            "LMSTUDIO_API_KEY": "local",
        }
        env.pop("CODEX_HOME", None)

        out = run(graff, workspace, env, "init", "--provider", "lmstudio", "--model", "mock", "--candidates", "2").stdout
        assert "initialized learned agent 'graff-root'" in out, out
        assert "lmstudio/mock with 2 candidate arm(s)" in out, out

        kit = workspace / ".graff" / "learn-kit"
        config = json.loads((kit / "config.json").read_text(encoding="utf-8"))
        assert config["agent_name"] == "graff-root"
        assert config["auto"]["enabled"] is True, "the generated loop must be able to promote on its own"
        assert config["gate"]["default_candidates"] == 2
        assert config["cohort"]["provider"] == "lmstudio" and config["cohort"]["model"] == "mock"
        assert config["mutator"]["pass_env"] == ["LMSTUDIO_API_KEY"], config["mutator"]["pass_env"]
        assert_pins(config)

        arms = json.loads((kit / "arms.json").read_text(encoding="utf-8"))
        assert len(arms["arms"]) == 2
        parent = (kit / "parent.md").read_text(encoding="utf-8")
        target = arms["targets"]["root_workflow"]
        assert parent.count(target) == 1, "the mutation target must occur exactly once in the parent"
        assert arms["protected_substrings"], "at least one invariant must be protected"
        for item in arms["protected_substrings"]:
            assert item in parent, f"protected substring is missing from the parent: {item}"
        for arm in arms["arms"]:
            # lmstudio cannot apply a reasoning-effort pin, so none is claimed.
            assert arm.get("effort") is None, arm
        settings = json.loads((kit / "evaluator.json").read_text(encoding="utf-8"))
        assert settings["effort"] is None, settings

        primary = json.loads((kit / "primary.json").read_text(encoding="utf-8"))
        holdout = json.loads((kit / "holdout.json").read_text(encoding="utf-8"))
        assert primary["suite_id"] != holdout["suite_id"]
        assert not units(primary) & units(holdout), "the holdout must be independent of the primary suite"
        assert len(units(primary)) >= config["gate"]["minimum_pairs"]
        assert len(units(holdout)) >= config["gate"]["minimum_pairs"]

        verified = json.loads(run(graff, workspace, env, "verify").stdout)
        assert verified["integrity"] == "ok" and verified["pins_verified"] is True, verified
        assert verified["agent_name"] == "graff-root" and verified["generation"] == 0

        # A second init must not touch the pinned files the store depends on.
        before = {name: digest(kit / name) for name in ("primary.json", "holdout.json", "parent.md", "config.json")}
        again = run(graff, workspace, env, "init", succeeds=False)
        assert "AlreadyInitialized" in again.stderr, again.stderr
        assert {name: digest(kit / name) for name in before} == before, "re-init rewrote pinned files"
        still = json.loads(run(graff, workspace, env, "verify").stdout)
        assert still["pins_verified"] is True and still["config_id"] == verified["config_id"]

    print("learning bootstrap E2E passed", file=sys.stdout)


if __name__ == "__main__":
    main()
