#!/usr/bin/env python3
"""Drive delegated speed choices through the binary to a local Responses mock."""

import importlib.util
from pathlib import Path
import tempfile


spec = importlib.util.spec_from_file_location(
    "review_fixture", Path(__file__).with_name("test-review-mode.py")
)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

ROOT = ("gpt-6.2-astra", None)
STANDARD = ("gpt-6.2-sol", None)
ULTRAFAST = ("gpt-6.2-sol", "ultrafast")


def run_case(name, tool, arguments, expected, rejection=None):
    def responses(request):
        if request.ordinal == 1:
            return fixture.tool(tool, arguments, request.ordinal)
        return fixture.message("No findings.", request.ordinal)

    with tempfile.TemporaryDirectory(prefix="graff-worker-tier-") as workspace:
        mock = fixture.CodexMock(events_for_request=responses)
        port = mock.start()
        process = fixture.start_graff(
            workspace, port,
            extra_args=["--model", "codex/gpt-6.2-astra", "--subagent-model", "gpt-6.2-sol"],
        )
        try:
            events = fixture.send(process, {
                "type": "user",
                "text": "Run a thorough audit of the error handling across the codebase and report what you find.",
            })
            assert events[-1]["type"] == "turn", events[-1]
            outcomes = [event for event in events
                        if event.get("type") == "tool_result" and event.get("name") == tool]
            assert len(outcomes) == 1, outcomes
            assert outcomes[0]["is_error"] == (rejection is not None), outcomes[0]
            if rejection:
                assert rejection in outcomes[0]["text"], outcomes[0]
            requests = mock.recorded_requests()
            observed = [(request.body["model"], request.body.get("service_tier"))
                        for request in requests]
            assert observed == expected, (name, observed, expected)
            for request, (_, tier) in zip(requests, expected):
                if tier is None:
                    assert "service_tier" not in request.body
        finally:
            fixture.close(process, name)
            mock.stop()


def main():
    child = {
        "description": "Inspect one component",
        "prompt": "Inspect the parser and report what you find.",
        "model": "codex/gpt-6.2-sol",
        "run_in_background": False,
        "isolation": "shared_cwd",
    }
    run_case("ultrafast child", "subagent", {**child, "service_tier": "ultrafast"},
             [ROOT, ULTRAFAST, ROOT])
    run_case("standard child", "subagent", child, [ROOT, STANDARD, ROOT])
    run_case("Astra rejects ultrafast", "subagent",
             {**child, "model": "codex/gpt-6.2-astra", "service_tier": "ultrafast"},
             [ROOT, ROOT], "do not offer the requested service tier")
    run_case("parallel workers", "workflow", {
        "service_tier": "ultrafast",
        "phases": [{
            "title": "Find problems",
            "tasks": [
                {"description": "Inspect settings names", "prompt": "Audit settings labels.",
                 "isolation": "shared_cwd"},
                {"description": "Analyze JSON encoding", "prompt": "Look for JSON encoding defects.",
                 "isolation": "shared_cwd"},
            ],
        }],
    }, [ROOT, ULTRAFAST, ULTRAFAST, ROOT])
    print("ok    delegated service tiers reach supported workers and preserve the default")


if __name__ == "__main__":
    main()
