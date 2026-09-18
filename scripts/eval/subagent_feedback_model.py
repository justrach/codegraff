"""Routed offline replies for parent/child feedback lifecycle evals."""
import json
import shlex
import threading

from mock_model import ScriptedModel

NOTE = "FEEDBACK_SCOPE_UPDATE: include the revised scope in your report."


def bash(code):
    return {"tool": "bash", "arguments": {"command": "python3 -c " + shlex.quote(code)}}


def wait_file(name):
    return (
        "from pathlib import Path\nimport time\n"
        "deadline = time.monotonic() + 15\n"
        f"while not Path({name!r}).exists():\n"
        " if time.monotonic() > deadline: raise RuntimeError('fixture timed out')\n"
        " time.sleep(.01)\n"
    )


class FeedbackModel(ScriptedModel):
    def __init__(self, scenario, load_tools=False):
        super().__init__([])
        if scenario not in ("tool", "final"):
            raise ValueError(f"unknown feedback scenario: {scenario}")
        self.scenario = scenario
        self.load_tools = load_tools
        self.parent_calls = 0
        self.child_calls = 0
        self.child_started = threading.Event()
        self.feedback_acked = threading.Event()
        self.checked = False
        self.problem = "child never consumed feedback"

    def next_reply(self, body):
        super().next_reply(body)  # retain the same request evidence as tier 2
        messages = body.get("messages", [])
        first_user = next((m for m in messages if m.get("role") == "user"), {})
        if "CHILD_FEEDBACK_FIXTURE" in json.dumps(first_user):
            return self.child_reply(messages)
        return self.parent_reply(messages)

    def child_reply(self, messages):
        step = self.child_calls
        self.child_calls += 1
        if step == 0:
            self.child_started.set()
            if self.scenario == "final":
                if not self.feedback_acked.wait(15):
                    return {"text": "fixture timed out waiting for feedback acknowledgement"}
                return {"text": "EARLY_REPORT"}
            setup = "from pathlib import Path\nPath('child-ready').write_text('ready')\n"
            return bash(setup + wait_file("child-release") + "print('TOOL_FINISHED')\n")
        notes = [i for i, m in enumerate(messages) if m.get("role") == "user" and NOTE in json.dumps(m)]
        tool_results = [i for i, m in enumerate(messages) if m.get("role") == "tool"]
        valid = step == 1 and len(notes) == 1 and "[Parent task feedback]" in json.dumps(messages[notes[0]])
        if self.scenario == "tool":
            valid = valid and bool(tool_results) and notes[0] > max(tool_results) and "TOOL_FINISHED" in json.dumps(messages)
        else:
            valid = valid and any(m.get("role") == "assistant" and "EARLY_REPORT" in json.dumps(m) for m in messages[:notes[0]])
        self.checked = valid
        self.problem = "feedback missing, duplicated, or delivered before the current operation finished"
        return {"text": "UPDATED_REPORT" if valid else "FEEDBACK_NOT_APPLIED"}

    def parent_reply(self, messages):
        step = self.parent_calls
        self.parent_calls += 1
        if self.load_tools:
            if step == 0:
                return {"tool": "load_tool_schemas", "arguments": {"tools": ["subagent", "agent_message", "agent_output"]}}
            step -= 1
        spawn = {"tool": "subagent", "arguments": {
            "description": "Feedback fixture child", "prompt": "CHILD_FEEDBACK_FIXTURE: complete the task and incorporate parent feedback.",
            "run_in_background": True,
        }}
        send = {"tool": "agent_message", "arguments": {"id": 1, "message": NOTE}}
        collect = {"tool": "agent_output", "arguments": {"id": 1, "wait_ms": 1}}
        late = {"tool": "agent_message", "arguments": {"id": 1, "message": "late feedback must be rejected"}}
        missing = {"tool": "agent_message", "arguments": {"id": 999999, "message": "unknown target"}}
        if self.scenario == "tool":
            replies = [spawn, bash(wait_file("child-ready")), send,
                       bash("from pathlib import Path; Path('child-release').write_text('release')"),
                       collect, late, missing]
        else:
            if step == 1 and not self.child_started.wait(15):
                return {"text": "fixture timed out waiting for the child's request"}
            if step == 2:
                self.feedback_acked.set()
            replies = [spawn, send, collect, late, missing]
        if step < len(replies):
            return replies[step]
        # The final verifier checks actual tool results in the parent's request,
        # rather than assuming a scripted request succeeded.
        outputs = [m.get("content", "") for m in messages if m.get("role") == "tool"]
        text = json.dumps(outputs)
        valid = self.checked and self.child_calls == 2 and all(s in text for s in
            ("feedback queued", "UPDATED_REPORT", "agent has already finished", "agent is not live"))
        return {"text": "FEEDBACK_TEST_DONE" if valid else "FEEDBACK_TEST_FAILED: " + self.problem}
