#!/usr/bin/env python3
"""Measure correctness at first completion and after two matched continuations."""
from __future__ import annotations

import argparse
from contextlib import contextmanager, nullcontext
import hashlib
import json
import os
from pathlib import Path
import queue
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

from fixture import TASK, PARTIAL, REFERENCE, materialize

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "scripts" / "eval"))
from mock_model import ScriptedModel  # noqa: E402

CLAIM = "\nEnd your final answer with a line containing only COMPLETE or INCOMPLETE."
VERIFY = (
    "Continue the same task. Independently verify the implementation against the "
    "whole contract, including overlooked acceptance conditions. Fix any issues "
    "you find before finishing." + CLAIM
)
CONTROL = (
    "Continue the same task. Spend this additional turn completing any remaining "
    "work on the original request. Finish when you consider the task complete." + CLAIM
)


@contextmanager
def mock(script):
    model = ScriptedModel(script, exhausted_text="INCOMPLETE")
    port = model.start(0)
    try:
        yield port, model.requests
    finally:
        model.stop()


def write_step(source):
    return {"tool": "bash", "arguments": {
        "command": "printf %s " + shlex.quote(source) + " > recovery.py",
    }}


def sandbox_prefix(graff):
    # The macOS profile is inherited by Bash and all of its descendants.
    # Linux's bubblewrap provides the same verifier visibility boundary. Use
    # real paths so worktree checkout and shared Git object paths are covered.
    repo = HERE.parents[1]
    objects = Path(subprocess.check_output(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd=repo, text=True,
    ).strip()).resolve()
    if sys.platform == "darwin" and shutil.which("sandbox-exec"):
        expressions = [f"(subpath {json.dumps(str(path))})" for path in (repo, objects)]
        profile = ("(version 1)(allow default)(deny file-read* "
                   + " ".join(expressions) + ")"
                   + f"(allow file-read* (literal {json.dumps(str(graff))}))")
        return ["sandbox-exec", "-p", profile]
    if sys.platform == "linux" and shutil.which("bwrap"):
        hidden = ["--tmpfs", str(repo)]
        if not objects.is_relative_to(repo):
            hidden += ["--tmpfs", str(objects)]
        return ["bwrap", "--die-with-parent", "--unshare-pid", "--ro-bind", "/", "/",
                "--proc", "/proc", "--dev", "/dev", *hidden]
    return []


def phase(args, work, prompt, budget, script, resume=None):
    workspace = str(work)
    continuing = resume is not None
    allowed_env = ("PATH", "LANG", *args.model_key_env)
    env = {key: os.environ[key] for key in allowed_env if key in os.environ}
    scratch = work / ".eval-tmp"
    scratch.mkdir(exist_ok=True)
    env.update(HOME=workspace, TMPDIR=str(scratch), GRAFF_NO_TELEMETRY="1",
               GRAFF_BEHAVIOR_UPLOAD="off",
               GRAFF_FLEET="off", GRAFF_LEARN_AUTO="off", GRAFF_NO_SMOLIFY="1",
               GRAFF_NO_CODEDB_GUARD="1", NO_COLOR="1",
               MOCKLOCAL_API_KEY="local", ACP_PROTOCOL_VERSION="1")
    config = work / "eval-mcp.json"
    config.write_text('{"mcpServers":{}}')
    settings = work / ".harness"
    settings.mkdir(exist_ok=True)
    (settings / "settings.json").write_text('{"ai_title":false}')
    env["GRAFF_MCP_CONFIG"] = str(config)
    started = time.monotonic()
    metrics = {}
    status = "protocol_error"
    with (nullcontext((None, [])) if args.model else mock(script)) as (port, requests):
        model_name = args.model or "mocklocal/mock"
        if port:
            router = work / ".graff" / ".config.router"
            router.parent.mkdir(exist_ok=True)
            router.write_text(json.dumps({
                "id": "mocklocal", "base_url": f"http://127.0.0.1:{port}/v1",
                "env_key": "MOCKLOCAL_API_KEY", "default_model": "mock",
            }))
        prefix = args.sandbox
        binary = args.graff
        if prefix[:1] == ["bwrap"]:
            binary = work / ".eval-graff"
            shutil.copy2(args.graff, binary)
            prefix = [*prefix, "--bind", workspace, workspace, "--"]
        command = prefix + [str(binary), "acp", "--model", model_name, "--old", "--no-lean",
                   "--no-telemetry", "--yolo", "--max-model-calls", str(budget)]
        with tempfile.TemporaryFile(mode="w+") as errors:
            with subprocess.Popen(command, cwd=work, env=env, text=True,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=errors, start_new_session=True) as process:
                mailbox = queue.Queue()

                def read():
                    for line in process.stdout:
                        try:
                            mailbox.put(json.loads(line))
                        except ValueError:
                            continue
                    mailbox.put(None)

                reader = threading.Thread(target=read, daemon=True)
                reader.start()
                deadline = started + args.timeout
                identifier = 0
                text = []

                def call(method, params, *, track=False):
                    nonlocal identifier
                    identifier += 1
                    process.stdin.write(json.dumps({
                        "jsonrpc": "2.0", "id": identifier, "method": method, "params": params,
                    }) + "\n")
                    process.stdin.flush()
                    while True:
                        value = mailbox.get(timeout=max(0.0, deadline - time.monotonic()))
                        if value is None:
                            raise RuntimeError("Agent exited before replying")
                        if value.get("id") == identifier:
                            if "error" in value:
                                raise RuntimeError(value["error"]["message"])
                            return value["result"]
                        if not track:
                            continue
                        if value.get("method") == "_codegraff/usage":
                            metrics["usage"] = value["params"]["usage"]
                        update = value.get("params", {}).get("update", {})
                        update_kind = update.get("sessionUpdate")
                        if update_kind == "agent_message_chunk":
                            text.append(update.get("content", {}).get("text", ""))
                        elif update_kind in ("tool_call", "tool_call_update"):
                            if update_kind == "tool_call":
                                text.clear()
                        elif update_kind == "usage_update":
                            metrics["context_meter"] = update

                try:
                    call("initialize", {"protocolVersion": 1})
                    setup = {"cwd": workspace, "mcpServers": []}
                    if resume:
                        call("session/load", dict(setup, sessionId=resume))
                    else:
                        resume = call("session/new", setup)["sessionId"]
                    result = call("session/prompt", {
                        "sessionId": resume, "prompt": [{"type": "text", "text": prompt}],
                    }, track=True)
                    resume = result.get("_meta", {}).get("graff/durableSessionId", resume)
                    state = result["stopReason"]
                    final_lines = "".join(text).strip().splitlines()
                    status = ("claimed" if final_lines and final_lines[-1] == "COMPLETE"
                              else "no_claim") if state == "end_turn" else state
                except queue.Empty:
                    status = "timeout"
                except (OSError, RuntimeError, KeyError) as exc:
                    metrics["error"] = str(exc)
                finally:
                    # Close ACP before snapshotting, so no further candidate turn
                    # can run and the conversation is persisted for both arms.
                    process.stdin.close()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
                        status = "timeout"
                    reader.join(timeout=1)
                    errors.seek(0)
                    if status == "protocol_error":
                        metrics["stderr"] = errors.read()[-1500:]
        if port:
            metrics["mock_calls"] = len(requests)
            if continuing:
                prior = json.dumps(requests[0].get("messages", [])) if requests else ""
                metrics["restored_first_turn"] = (
                    "First repair finished." in prior and "Fix recovery.py." in prior
                )
    metrics["seconds"] = round(time.monotonic() - started, 3)
    return {"status": status, **metrics}, resume


def verify(work, seed):
    # Import the submission in a separate executable process on a disposable
    # snapshot. Keep the evaluator outside the candidate workspace.
    with tempfile.TemporaryDirectory(prefix="graff-recovery-grade-") as temp:
        source = Path(temp) / "recovery.py"
        candidate = work / "recovery.py"
        if candidate.is_symlink() or not candidate.is_file():
            return {"pass": False, "status": "missing_candidate"}
        shutil.copyfile(candidate, source)
        try:
            run = subprocess.run([sys.executable, "-I", "-B", str(HERE / "verify.py"),
                                  str(source), str(seed)],
                                 capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {"pass": False, "status": type(exc).__name__}
        passed = run.returncode == 0 and run.stdout.splitlines()[-1:] == ["RECOVERY_CHECKS_PASSED"]
        return {"pass": passed, "status": "passed" if passed else "failed",
                "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest()}


def paired(args, seed):
    with tempfile.TemporaryDirectory(prefix="graff-first-completion-") as temp:
        root = Path(temp)
        work = root / "work"
        checkpoint = root / "frozen"
        materialize(work, seed)
        first, session = phase(args, work, TASK + CLAIM, args.initial_calls,
                               [write_step(PARTIAL), {"text": "First repair finished.\nCOMPLETE"}])
        record = {"seed": seed, "first": first}
        if first["status"] != "claimed":
            return record
        shutil.copytree(work, checkpoint, symlinks=True)
        first["grader"] = verify(checkpoint, seed)
        arms = [
            ("verification", VERIFY, [write_step(REFERENCE), {"text": "Verified.\nCOMPLETE"}]),
            ("control", CONTROL, [{"text": "Continued.\nCOMPLETE"}]),
        ]
        for name, prompt, script in (arms if seed % 2 else reversed(arms)):
            # Keep cwd and HOME identical, so both independently reload the
            # same saved conversation and resume the exact same workspace.
            shutil.rmtree(work)
            shutil.copytree(checkpoint, work, symlinks=True)
            arm, _ = phase(args, work, prompt, args.followup_calls, script, session)
            arm["grader"] = verify(work, seed)
            record[name] = arm
        return record


def summary(records):
    claimed = [row for row in records if row["first"]["status"] == "claimed"]
    incorrect = [row for row in claimed if not row["first"]["grader"]["pass"]]
    correct = [row for row in claimed if row["first"]["grader"]["pass"]]

    def correct_completion(row, arm):
        return row[arm]["status"] == "claimed" and row[arm]["grader"]["pass"]

    def rate(count, eligible):
        return count / eligible if eligible else None

    arms = {}
    for arm in ("verification", "control"):
        rescued = sum(correct_completion(row, arm) for row in incorrect)
        regressed = sum(not row[arm]["grader"]["pass"] for row in correct)
        arms[arm] = {
            "rescued": rescued,
            "of_initially_incorrect": len(incorrect),
            "rescue_rate": rate(rescued, len(incorrect)),
            "regressed": regressed,
            "of_initially_correct": len(correct),
            "regression_rate": rate(regressed, len(correct)),
            "non_completions": sum(row[arm]["status"] != "claimed" for row in claimed),
        }

    return {
        "runs": len(records),
        "first_statuses": {status: sum(row["first"]["status"] == status for row in records)
                           for status in sorted({row["first"]["status"] for row in records})},
        "first_correct": len(correct),
        "false_completions": len(incorrect),
        "first_claims": len(claimed),
        "first_completion_correctness_rate": rate(len(correct), len(claimed)),
        "false_completion_rate": rate(len(incorrect), len(claimed)),
        "verified_first_pass_rate_over_all_runs": rate(len(correct), len(records)),
        **arms,
    }


def self_test(seed):
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp) / "work"
        materialize(work, seed)
        for content, expected in ((None, False), (PARTIAL, False), (REFERENCE, True)):
            source = work / "recovery.py"
            if content is None:
                source.unlink()
            else:
                source.write_text(content)
            result = verify(work, seed)
            assert result["pass"] == expected, result
    print("PASS missing and incomplete solutions rejected; reference accepted.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", type=Path)
    parser.add_argument("--model", help="Use a live API model (explicit opt-in).")
    parser.add_argument("--model-key-env", action="append", default=[], metavar="NAME",
                        help="Pass the named model credential from the environment.")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--repetitions", type=int, default=2)
    parser.add_argument("--initial-calls", type=int, default=20)
    parser.add_argument("--followup-calls", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(args.seed)
        return
    if args.graff is None or not args.graff.is_file():
        parser.error("--graff must point to an already built binary")
    if min(args.repetitions, args.initial_calls, args.followup_calls, args.timeout) < 1:
        parser.error("repetitions, budgets and timeout must be positive")
    if args.model_key_env and not args.model:
        parser.error("--model-key-env requires --model")
    if any(not os.environ.get(key) for key in args.model_key_env):
        parser.error("each --model-key-env must be present in the environment")
    args.graff = args.graff.resolve()
    args.sandbox = sandbox_prefix(args.graff)
    if args.model and not args.sandbox:
        parser.error("live evaluation requires sandbox-exec on macOS or bwrap on Linux")
    if args.sandbox:
        # Prove that an agent child process cannot open the verifier path.
        probe = subprocess.run(
            [*args.sandbox, "/bin/sh", "-c", 'test ! -r "$1"', "probe", str(HERE / "verify.py")],
            cwd="/", capture_output=True, timeout=10,
        )
        if probe.returncode != 0:
            if args.model:
                parser.error("checkout visibility isolation failed")
            args.sandbox = []

    records = [paired(args, seed) for seed in range(args.seed, args.seed + args.repetitions)]
    results = summary(records)
    metadata = {
        "source": "live" if args.model else "scripted plumbing control",
        "model": args.model,
        "workspace_isolation": args.sandbox[0] if args.sandbox else "scripted-only",
        "timeout_seconds_per_turn": args.timeout,
        "initial_call_budget": args.initial_calls,
        "matched_followup_call_budget": args.followup_calls,
        "grader_sha256": hashlib.sha256((HERE / "verify.py").read_bytes()).hexdigest(),
    }
    print(json.dumps({"settings": metadata, "summary": results, "runs": records}, indent=2))
    if not args.model and (results["false_completions"] != args.repetitions
                           or results["verification"]["rescued"] != args.repetitions
                           or results["control"]["rescued"] != 0
                           or results["control"]["non_completions"] != 0
                           or any(not row[arm]["restored_first_turn"]
                                  for row in records for arm in ("verification", "control"))):
        sys.exit("Scripted checkpoint/continuation control failed")


if __name__ == "__main__":
    main()
