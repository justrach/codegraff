"""Opt-in formal baseline gate for the prompt-genome DGM example.

The checked model describes shared harness lifecycle, never the candidate
prompt. An external pin file is a trust input, not a sandbox boundary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import secrets

REPO = Path(__file__).resolve().parents[1]
SCHEMA = "codegraff.dgm.formal-pin.v1"
RECEIPT_SCHEMA = "codegraff.dgm.formal-receipt.v1"
HEX = re.compile(r"[0-9a-f]{64}\Z")
SOURCE_FILES = (
    "src/agent_async_tools.zig", "src/agent_request.zig", "src/agent_steps.zig",
    "src/agent_tools.zig", "src/agent_stream.zig", "src/agent.zig",
    "src/jev_effort_state.zig", "src/jev_tool.zig", "src/effort_route.zig",
    "src/commands_effort.zig", "src/acp_config.zig", "src/jev_model_scope.zig",
    "src/acp_permission.zig", "src/acp_inbox.zig", "src/acp_live_turn.zig",
    "apps/native/lib/acp-transport.ts", "apps/native/lib/acp-client.ts",
    "apps/native/app/api/acp/route.ts", "src/http2_pool.zig",
    "src/http2_buffered.zig", "src/agent_stream_h2.zig", "src/http_client.zig",
    "examples/dgm_loop.py", "examples/dgm_formal_gate.py", "sdk/py/harness_sdk.py",
    "scripts/check-formal.py", "examples/replay_judge.py",
    "examples/dgm_eval_set.jsonl",
)


class GateError(RuntimeError):
    pass


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def external(path, repo=REPO):
    given = Path(path).expanduser()
    if not given.is_absolute():
        raise GateError("formal pin path must be absolute")
    resolved = given.resolve()
    if resolved == repo or repo in resolved.parents:
        raise GateError("formal pin must be outside the candidate source tree")
    return resolved


def route(value):
    if not isinstance(value, str) or not value or any(ord(ch) < 33 or ord(ch) > 126 for ch in value):
        raise GateError("model selector must be a nonempty printable token")
    return value


def create_pin(destination, binary, java, jar, main_model, replay_model, *, repo=REPO):
    """Explicitly copy the verifier bundle and write an external hash pin."""
    repo = Path(repo).resolve()
    destination = external(destination, repo)
    binary, java, jar = (Path(p).expanduser().resolve(strict=True) for p in (binary, java, jar))
    if destination.exists():
        raise GateError("pin destination already exists")
    for path in (binary, java, jar):
        if not path.is_file():
            raise GateError("a pinned executable or archive is missing")
    bundle_files = [Path("scripts/check-formal.py"), Path("examples/replay_judge.py"),
                    Path("examples/dgm_eval_set.jsonl")]
    bundle_files += [p.relative_to(repo) for p in sorted((repo / "formal").glob("*.tla"))]
    bundle_files += [p.relative_to(repo) for p in sorted((repo / "formal").glob("*.cfg"))]
    if not any(p.name == "AsyncTools.tla" for p in bundle_files) or not any(
            p.name == "EffortSelection.tla" for p in bundle_files):
        raise GateError("required formal models are missing")
    destination.mkdir(mode=0o700, parents=True)
    bundle = destination / "bundle"
    bundle.mkdir(mode=0o700)
    for rel in bundle_files:
        target = bundle / rel
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(repo / rel, target)
        target.chmod(0o600)
    manifest = {
        "schema": SCHEMA, "source_root": str(repo), "bundle_root": str(bundle),
        "source_files": {str(rel): digest(repo / rel) for rel in
                         sorted(set(map(Path, SOURCE_FILES)) | set(bundle_files))},
        "bundle_files": {str(rel): digest(bundle / rel) for rel in bundle_files},
        "binary": {"path": str(binary), "sha256": digest(binary)},
        "java": {"path": str(java), "sha256": digest(java)},
        "jar": {"path": str(jar), "sha256": digest(jar)},
        "heldout_hash": digest(bundle / "examples/dgm_eval_set.jsonl"),
        "main_model": route(main_model), "replay_model": route(replay_model),
    }
    pin = destination / "pin.json"
    private_write(pin, canonical(manifest))
    (destination / "receipts").mkdir(mode=0o700)
    return pin


class FormalGate:
    def __init__(self, pin_path, *, repo=REPO, checker=None):
        self.repo = Path(repo).resolve()
        self.pin_path = external(pin_path, self.repo)
        try:
            raw = self.pin_path.read_bytes()
            self.pin = json.loads(raw)
        except (OSError, ValueError) as error:
            raise GateError("formal pin is missing or malformed") from error
        if self.pin.get("schema") != SCHEMA or self.pin.get("source_root") != str(self.repo):
            raise GateError("formal pin does not match this source tree")
        self.pin_sha256 = hashlib.sha256(raw).hexdigest()
        self.bundle = external(self.pin["bundle_root"], self.repo)
        self.receipts = self.pin_path.parent / "receipts"
        self.checker = checker or self._run_checker
        self.checked_identity = None
        self.check_output_sha256 = None
        self.check_log_path = None
        self.key_path = os.environ.get("GRAFF_SCORE_KEY_FILE")
        if not self.key_path:
            raise GateError("opt-in formal gate requires a usable score-signing key")
        try:
            self.key_sha256 = digest(self.key_path)
        except OSError as error:
            raise GateError("opt-in formal gate requires a usable score-signing key") from error
        self.verify_identity()

    def verify_identity(self):
        try:
            if digest(self.pin_path) != self.pin_sha256:
                raise GateError("formal pin changed")
            if (not Path(self.key_path).is_file() or not Path(self.key_path).read_bytes().strip()
                    or digest(self.key_path) != self.key_sha256):
                raise GateError("opt-in formal gate requires a usable score-signing key")
            route(self.pin["main_model"])
            route(self.pin["replay_model"])
            source = self.pin["source_files"]
            bundle = self.pin["bundle_files"]
            if not set(SOURCE_FILES) <= set(source) or not bundle or not self.receipts.is_dir():
                raise GateError("formal pin inventory is incomplete")
            formal_source = {p.relative_to(self.repo).as_posix() for suffix in ("*.tla", "*.cfg")
                             for p in (self.repo / "formal").glob(suffix)}
            if formal_source != {name for name in source if name.startswith("formal/")}:
                raise GateError("formal source file set changed")
            for relative, expected in source.items():
                if not HEX.fullmatch(expected) or digest(self.repo / relative) != expected:
                    raise GateError("pinned source changed: " + relative)
            for relative, expected in bundle.items():
                if not HEX.fullmatch(expected) or digest(self.bundle / relative) != expected:
                    raise GateError("pinned formal bundle changed: " + relative)
            for name in ("binary", "java", "jar"):
                entry = self.pin[name]
                if not HEX.fullmatch(entry["sha256"]) or digest(entry["path"]) != entry["sha256"]:
                    raise GateError("pinned " + name + " changed")
            if self.pin["heldout_hash"] != bundle["examples/dgm_eval_set.jsonl"]:
                raise GateError("held-out set pin mismatch")
            identity = hashlib.sha256(canonical(self.pin)).hexdigest()
            if self.checked_identity is not None and identity != self.checked_identity:
                raise GateError("formal baseline identity drifted")
            return identity
        except (KeyError, OSError, TypeError, ValueError) as error:
            if isinstance(error, GateError):
                raise
            raise GateError("formal baseline pin could not be verified") from error

    def _run_checker(self):
        env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ}
        env.update(JAVA=self.pin["java"]["path"], TLA2TOOLS=self.pin["jar"]["path"],
                   PYTHONDONTWRITEBYTECODE="1")
        try:
            result = subprocess.run([sys.executable, str(self.bundle / "scripts/check-formal.py")],
                                    cwd=self.bundle, env=env, capture_output=True, timeout=900)
            evidence = result.stdout + result.stderr
        except subprocess.TimeoutExpired as error:
            evidence = (error.stdout or b"") + (error.stderr or b"")
            log = self.receipts / ("check-" + secrets.token_hex(8) + ".log")
            private_write(log, evidence[:65536] + b"\n[checker timed out; output bounded]\n")
            raise GateError("formal model check timed out; see private checker log") from error
        log = self.receipts / ("check-" + secrets.token_hex(8) + ".log")
        private_write(log, evidence[:65536] + (b"\n[output truncated]\n" if len(evidence) > 65536 else b""))
        self.check_log_path = log
        if result.returncode != 0:
            raise GateError("formal model check failed; see private checker log")
        return hashlib.sha256(evidence).hexdigest()

    def ensure_checked(self):
        identity = self.verify_identity()
        if self.checked_identity is None:
            try:
                output_sha = self.checker()
            except (OSError, subprocess.TimeoutExpired) as error:
                raise GateError("formal model check unavailable") from error
            if not isinstance(output_sha, str) or not HEX.fullmatch(output_sha):
                raise GateError("formal checker returned no valid receipt")
            if self.verify_identity() != identity:
                raise GateError("formal baseline changed during model check")
            self.checked_identity = identity
            self.check_output_sha256 = output_sha
        return identity

    @property
    def binary(self):
        return self.pin["binary"]["path"]

    @property
    def main_model(self):
        return self.pin["main_model"]

    def replay_env(self):
        self.ensure_checked()
        return {"GRAFF_HARNESS_BIN": self.binary,
                "GRAFF_REPLAY_JUDGE": str(self.bundle / "examples/replay_judge.py"),
                "GRAFF_EVAL_SET_FILE": str(self.bundle / "examples/dgm_eval_set.jsonl"),
                "GRAFF_EVAL_SET_HASH": self.pin["heldout_hash"],
                "GRAFF_EVAL_MODEL": self.pin["replay_model"]}

    def prepare_candidate(self, prompt):
        self.ensure_checked()
        prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()
        payload = {"schema": RECEIPT_SCHEMA, "phase": "before_evaluation",
                   "candidate_prompt_sha256": prompt_sha,
                   "formal_identity_sha256": self.checked_identity,
                   "checker_output_sha256": self.check_output_sha256,
                   "checker_log_file": self.check_log_path.name if self.check_log_path else None,
                   "checker_log_sha256": digest(self.check_log_path) if self.check_log_path else None,
                   "binary_sha256": self.pin["binary"]["sha256"]}
        path = self.receipts / ("candidate-" + prompt_sha + "-" + secrets.token_hex(8) + ".json")
        data = canonical(payload)
        private_write(path, data)
        return {"path": path, "sha256": hashlib.sha256(data).hexdigest(),
                "prompt_sha256": prompt_sha}

    def finish_candidate(self, prepared, prompt, report, heldout_hash):
        self.ensure_checked()  # cheap rehash; never silently rerun TLC on drift
        prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()
        if prompt_sha != prepared["prompt_sha256"] or digest(prepared["path"]) != prepared["sha256"]:
            raise GateError("candidate prompt or preflight receipt changed")
        if heldout_hash and heldout_hash != self.pin["heldout_hash"]:
            raise GateError("held-out replay used a different evaluation set")
        report_sha = hashlib.sha256(report.encode()).hexdigest()
        if len(prompt.encode()) > 1048576 or len(report.encode()) > 1048576:
            raise GateError("candidate evidence exceeds private receipt bound")
        payload = {"schema": RECEIPT_SCHEMA, "phase": "before_score",
                   "preflight_sha256": prepared["sha256"], "candidate_prompt_sha256": prompt_sha,
                   "preflight_file": prepared["path"].name,
                   "candidate_prompt": prompt, "report": report,
                   "report_sha256": report_sha, "heldout_eval_set_hash": heldout_hash,
                   "formal_identity_sha256": self.checked_identity,
                   "checker_output_sha256": self.check_output_sha256,
                   "checker_log_file": self.check_log_path.name if self.check_log_path else None,
                   "checker_log_sha256": digest(self.check_log_path) if self.check_log_path else None,
                   "binary_sha256": self.pin["binary"]["sha256"],
                   "main_model": self.main_model, "replay_model": self.pin["replay_model"]}
        data = canonical(payload)
        if len(data) > 2 * 1048576 + 4096:
            raise GateError("serialized private receipt exceeds bound")
        artifact = self.artifact_digest(data, report_sha, prompt_sha)
        path = self.receipts / ("score-" + artifact + ".json")
        private_write(path, data)
        return artifact

    @staticmethod
    def artifact_digest(data, report_sha, prompt_sha):
        return hashlib.sha256(b"dgm-formal-artifact-v1\0" + hashlib.sha256(data).digest() +
                              bytes.fromhex(report_sha) + bytes.fromhex(prompt_sha)).hexdigest()

    def verify_score_receipt(self, row, prompt=None):
        """Validate the private evidence named by a signed formal score row."""
        self.ensure_checked()
        artifact = row.get("artifact_sha", "")
        if row.get("judge_id") != "replay-v1+formal-v1" or not HEX.fullmatch(artifact):
            raise GateError("formal score has no valid artifact reference")
        path = self.receipts / ("score-" + artifact + ".json")
        try:
            with path.open("rb") as stream:
                data = stream.read(2 * 1048576 + 4097)
            if len(data) > 2 * 1048576 + 4096:
                raise GateError("formal score receipt exceeds bound")
            receipt = json.loads(data)
            if data != canonical(receipt):
                raise GateError("formal score receipt is not canonical")
            candidate = receipt["candidate_prompt"]
            report = receipt["report"]
            prompt_sha = hashlib.sha256(candidate.encode()).hexdigest()
            report_sha = hashlib.sha256(report.encode()).hexdigest()
            if (receipt["schema"] != RECEIPT_SCHEMA or receipt["phase"] != "before_score"
                    or receipt["candidate_prompt_sha256"] != prompt_sha
                    or row.get("prompt_sha") != prompt_sha[:16]
                    or receipt["report_sha256"] != report_sha
                    or self.artifact_digest(data, report_sha, prompt_sha) != artifact
                    or receipt["formal_identity_sha256"] != self.checked_identity
                    or not HEX.fullmatch(receipt["checker_output_sha256"])
                    or receipt["binary_sha256"] != self.pin["binary"]["sha256"]
                    or receipt["main_model"] != self.main_model
                    or receipt["replay_model"] != self.pin["replay_model"]
                    or receipt["heldout_eval_set_hash"] != row.get("eval_set_hash", "")
                    or (row.get("eval_set_hash") and row["eval_set_hash"] != self.pin["heldout_hash"])
                    or (prompt is not None and candidate != prompt)):
                raise GateError("formal score receipt does not match its score row")
            preflight_name = receipt["preflight_file"]
            if not re.fullmatch(r"candidate-[0-9a-f]{64}-[0-9a-f]{16}\.json", preflight_name):
                raise GateError("formal preflight name mismatch")
            preflight = self.receipts / preflight_name
            if (preflight.parent != self.receipts
                    or digest(preflight) != receipt["preflight_sha256"]):
                raise GateError("formal preflight receipt mismatch")
            before = json.loads(preflight.read_bytes())
            if (before.get("candidate_prompt_sha256") != prompt_sha or
                    before.get("formal_identity_sha256") != self.checked_identity or
                    before.get("checker_output_sha256") != receipt["checker_output_sha256"] or
                    before.get("checker_log_file") != receipt["checker_log_file"] or
                    before.get("checker_log_sha256") != receipt["checker_log_sha256"]):
                raise GateError("formal preflight identity mismatch")
            log_name, log_sha = receipt["checker_log_file"], receipt["checker_log_sha256"]
            if log_name is not None or log_sha is not None:
                if (not isinstance(log_name, str) or
                        not re.fullmatch(r"check-[0-9a-f]{16}\.log", log_name) or
                        not isinstance(log_sha, str) or not HEX.fullmatch(log_sha) or
                        digest(self.receipts / log_name) != log_sha):
                    raise GateError("archived checker log changed")
            return receipt
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise GateError("formal score receipt unavailable or malformed") from error


def main():
    parser = argparse.ArgumentParser(description="Pin or verify the optional DGM formal gate")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--pin", help="new external directory; must not exist")
    action.add_argument("--check", help="existing external pin.json to verify")
    action.add_argument("--verify-row", help="JSON score row whose formal receipt must verify")
    parser.add_argument("--pin-file", help="external pin.json for --verify-row")
    parser.add_argument("--candidate-sha256", help="full prompt SHA-256 for --check")
    parser.add_argument("--binary")
    parser.add_argument("--java")
    parser.add_argument("--jar")
    parser.add_argument("--main-model")
    parser.add_argument("--replay-model")
    args = parser.parse_args()
    if args.pin:
        if not all((args.binary, args.java, args.jar, args.main_model, args.replay_model)):
            parser.error("--pin requires --binary, --java, --jar, and both model selectors")
        print(create_pin(args.pin, args.binary, args.java, args.jar,
                         args.main_model, args.replay_model))
    elif args.check:
        if not args.candidate_sha256 or not HEX.fullmatch(args.candidate_sha256):
            parser.error("--check requires --candidate-sha256")
        gate = FormalGate(args.check)
        gate.ensure_checked()
        print(json.dumps({"schema": "codegraff.dgm.formal-check.v1", "ok": True,
                          "candidate_prompt_sha256": args.candidate_sha256,
                          "formal_identity_sha256": gate.checked_identity,
                          "checker_output_sha256": gate.check_output_sha256,
                          "binary_sha256": gate.pin["binary"]["sha256"]}, sort_keys=True))
    else:
        if not args.pin_file:
            parser.error("--verify-row requires --pin-file")
        sys.path.insert(0, str(REPO / "sdk/py"))
        from harness_sdk import verify_score
        gate = FormalGate(args.pin_file)
        with Path(args.verify_row).open("rb") as stream:
            raw = stream.read(1048577)
        if len(raw) > 1048576:
            raise GateError("score row exceeds verifier bound")
        row = json.loads(raw)
        if not verify_score(Path(gate.key_path).read_bytes().strip(), row):
            raise GateError("score row signature invalid")
        gate.verify_score_receipt(row)
        print(json.dumps({"schema": "codegraff.dgm.formal-score-check.v1", "ok": True,
                          "artifact_sha": row["artifact_sha"],
                          "formal_identity_sha256": gate.checked_identity}, sort_keys=True))


if __name__ == "__main__":
    main()
