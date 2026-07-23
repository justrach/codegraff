#!/usr/bin/env python3
"""Deterministic SDK egress checks for the learning-privacy contract."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import threading
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SDK_PATH = ROOT / "sdk" / "py" / "harness_sdk.py"


def load_sdk() -> Any:
    spec = importlib.util.spec_from_file_location("privacy_test_harness_sdk", SDK_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Response:
    def read(self) -> bytes:
        return b"{}"

    def __enter__(self) -> "Response":
        return self

    def __exit__(self, *_args: Any) -> None:
        pass


def emit(module: Any, mode: str | None, telemetry_off: bool = False) -> list[dict[str, Any]]:
    captured: list[dict[str, Any]] = []
    ready = threading.Event()

    def fake_urlopen(request: Any, timeout: int = 0) -> Response:
        del timeout
        captured.append(json.loads(request.data))
        ready.set()
        return Response()

    original_urlopen = module.urllib.request.urlopen
    original_id = module._sdk_install_id
    original_env = os.environ.copy()
    try:
        module.urllib.request.urlopen = fake_urlopen
        module._sdk_install_id = lambda: "0" * 32
        for key in ("GRAFF_LEARNING_PRIVACY", "GRAFF_NO_TELEMETRY"):
            os.environ.pop(key, None)
        if mode is not None:
            os.environ["GRAFF_LEARNING_PRIVACY"] = mode
        if telemetry_off:
            os.environ["GRAFF_NO_TELEMETRY"] = "1"
        module._fleet_signal(
            "propose",
            {
                "niche": "reviewer",
                "prompt_sha": "0123456789abcdef",
                "prompt_text": "OPENAI_API_KEY=sk-proj-test-only",
            },
        )
        ready.wait(1)
        return captured
    finally:
        module.urllib.request.urlopen = original_urlopen
        module._sdk_install_id = original_id
        os.environ.clear()
        os.environ.update(original_env)


def encoded(payload: dict[str, Any]) -> str:
    return json.dumps(payload, separators=(",", ":"))


def local_pull_requests(module: Any, mode: str | None) -> list[Any]:
    requests: list[Any] = []
    original_urlopen = module.urllib.request.urlopen
    original_env = os.environ.copy()
    try:
        module.urllib.request.urlopen = lambda request, timeout=0: requests.append(request)
        os.environ.pop("GRAFF_LEARNING_PRIVACY", None)
        if mode is not None:
            os.environ["GRAFF_LEARNING_PRIVACY"] = mode
        harness = module.Harness.__new__(module.Harness)
        assert harness.pull_elites("test-provider") == []
        return requests
    finally:
        module.urllib.request.urlopen = original_urlopen
        os.environ.clear()
        os.environ.update(original_env)


def main() -> int:
    sdk = load_sdk()
    assert emit(sdk, None) == []
    assert emit(sdk, "LOCAL") == []
    assert emit(sdk, "unknown") == []
    assert emit(sdk, "aggregate", telemetry_off=True) == []

    aggregate = emit(sdk, "aggregate")
    assert len(aggregate) == 1
    aggregate_text = encoded(aggregate[0])
    assert "prompt_text" not in aggregate_text
    assert "sk-proj-test-only" not in aggregate_text
    assert "0123456789abcdef" in aggregate_text

    templates = emit(sdk, "templates")
    assert len(templates) == 1
    assert "prompt_text" not in encoded(templates[0])
    assert local_pull_requests(sdk, None) == []
    assert local_pull_requests(sdk, "LOCAL") == []

    ts = (ROOT / "sdk" / "ts" / "harness.ts").read_text()
    assert 'const privacy = process.env.GRAFF_LEARNING_PRIVACY ?? "local"' in ts
    assert "delete admitted.prompt_text" in ts
    assert 'includes(process.env.GRAFF_LEARNING_PRIVACY ?? "local")) return []' in ts
    print("privacy efficacy: 8/8 SDK egress cases passed; prompt canary never transmitted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
