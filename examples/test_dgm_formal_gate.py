"""Offline controls for the optional Python DGM formal baseline gate."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dgm_formal_gate as formal
import dgm_loop as loop
from harness_sdk import score_signature


class FormalGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("graff", "java", "tla.jar"):
            (self.root / name).write_bytes(name.encode())
        self.key = self.root / "score.key"
        self.key.write_bytes(b"private-test-key")
        self.env = patch.dict(os.environ, {"GRAFF_SCORE_KEY_FILE": str(self.key)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.pin = formal.create_pin(self.root / "pin", self.root / "graff",
                                     self.root / "java", self.root / "tla.jar",
                                     "codex/primary", "codex/replay")
        self.calls = 0

    def checker(self):
        self.calls += 1
        return "a" * 64

    def test_receipt_resolves_from_artifact_and_tlc_runs_once(self):
        gate = formal.FormalGate(self.pin, checker=self.checker)
        def recorded_check():
            output = self.checker()
            gate.check_log_path = gate.receipts / "check-0000000000000000.log"
            formal.private_write(gate.check_log_path, b"finite model checks passed\n")
            return output
        gate.checker = recorded_check
        prompt = "One changed behavior"
        for report in ("first child report", "second child report"):
            before = gate.prepare_candidate(prompt)
            artifact = gate.finish_candidate(before, prompt, report, gate.pin["heldout_hash"])
            row = {"judge_id": "replay-v1+formal-v1", "artifact_sha": artifact,
                   "prompt_sha": hashlib.sha256(prompt.encode()).hexdigest()[:16],
                   "eval_set_hash": gate.pin["heldout_hash"]}
            receipt = gate.verify_score_receipt(row, prompt)
            self.assertEqual(receipt["report"], report)
            self.assertEqual((gate.receipts / ("score-" + artifact + ".json")).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.calls, 1)
        self.assertEqual(gate.replay_env()["GRAFF_EVAL_MODEL"], "codex/replay")
        self.assertEqual(gate.main_model, "codex/primary")
        # A later TLC invocation may print different runtime statistics.
        later = formal.FormalGate(self.pin, checker=lambda: "b" * 64)
        later.ensure_checked()
        self.assertEqual(later.verify_score_receipt(row, prompt)["report"], "second child report")
        gate.check_log_path.write_bytes(b"changed model-check log\n")
        with self.assertRaises(formal.GateError):
            later.verify_score_receipt(row, prompt)

    def test_tamper_and_missing_receipt_fail_closed(self):
        gate = formal.FormalGate(self.pin, checker=self.checker)
        prompt = "A prompt"
        before = gate.prepare_candidate(prompt)
        artifact = gate.finish_candidate(before, prompt, "report", gate.pin["heldout_hash"])
        row = {"judge_id": "replay-v1+formal-v1", "artifact_sha": artifact,
               "prompt_sha": hashlib.sha256(prompt.encode()).hexdigest()[:16],
               "eval_set_hash": gate.pin["heldout_hash"]}
        with self.assertRaises(formal.GateError):
            gate.verify_score_receipt(dict(row, eval_set_hash="b" * 64))
        with self.assertRaises(formal.GateError):
            gate.verify_score_receipt(dict(row, artifact_sha="0" * 64))
        path = gate.receipts / ("score-" + artifact + ".json")
        path.write_bytes(path.read_bytes().replace(b"report", b"forged"))
        with self.assertRaises(formal.GateError):
            gate.verify_score_receipt(row)

    def test_key_and_source_identity_drift_fail_closed(self):
        gate = formal.FormalGate(self.pin, checker=self.checker)
        gate.ensure_checked()
        self.key.write_bytes(b"rotated-key")
        with self.assertRaises(formal.GateError):
            gate.ensure_checked()
        self.key.write_bytes(b"private-test-key")
        (self.pin.parent / "bundle" / "formal" / "AsyncTools.tla").write_text("tampered")
        with self.assertRaises(formal.GateError):
            gate.ensure_checked()
        self.assertEqual(self.calls, 1)

    def test_external_pin_and_model_validation(self):
        with self.assertRaises(formal.GateError):
            formal.create_pin(formal.REPO / "not-external", self.root / "graff",
                              self.root / "java", self.root / "tla.jar", "a", "b")
        with self.assertRaises(formal.GateError):
            formal.route(" ")

    def test_signed_formal_archive_row_requires_matching_receipt(self):
        gate = formal.FormalGate(self.pin, checker=self.checker)
        prompt = "archived candidate"
        prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()[:16]
        before = gate.prepare_candidate(prompt)
        artifact = gate.finish_candidate(before, prompt, "private report", gate.pin["heldout_hash"])
        row = {"kind": "score", "prompt_sha": prompt_sha, "parent_sha": "",
               "score": 0.9, "score_run_id": "run", "judge_id": "replay-v1+formal-v1",
               "artifact_sha": artifact, "eval_set_hash": gate.pin["heldout_hash"]}
        row["sig"] = score_signature(self.key.read_bytes(), prompt_sha, "", 0.9,
                                     "run", row["judge_id"], artifact, row["eval_set_hash"])
        archive = self.root / "archive.jsonl"
        archive.write_text(json.dumps({"kind": "prompt", "prompt_sha": prompt_sha,
                                       "text": prompt}) + "\n" + json.dumps(row) + "\n")
        with patch.object(loop, "archive_paths", return_value=[str(archive)]):
            genomes, scores, _ = loop.load_archive(gate)
            self.assertEqual(scores[prompt_sha], [0.9])
            (gate.receipts / ("score-" + artifact + ".json")).unlink()
            _, scores, _ = loop.load_archive(gate)
            self.assertNotIn(prompt_sha, scores)


class LoopGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("graff", "java", "tla.jar"):
            (self.root / name).write_bytes(name.encode())
        self.key = self.root / "score.key"
        self.key.write_bytes(b"private-test-key")
        self.env = patch.dict(os.environ, {"GRAFF_SCORE_KEY_FILE": str(self.key)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.pin = formal.create_pin(self.root / "pin", self.root / "graff",
                                     self.root / "java", self.root / "tla.jar",
                                     "codex/primary", "codex/replay")

    class FakeHarness:
        instances = []
        def __init__(self, **kwargs):
            self.kwargs = kwargs
            self.calls = []
            self.scores = []
            self.closed = False
            self.instances.append(self)
        def ask(self, prompt):
            self.calls.append(prompt)
            return "candidate prompt" if len(self.calls) == 1 else "child report"
        def score(self, *args, **kwargs):
            self.scores.append((args, kwargs))
        def close(self):
            self.closed = True

    def test_gate_failure_precedes_paid_model_launch(self):
        self.FakeHarness.instances.clear()
        class RejectGate:
            def __init__(self, path):
                pass
            def ensure_checked(self):
                raise formal.GateError("offline checker rejected")
        with patch.dict(os.environ, {"GRAFF_DGM_FORMAL_PIN": "/unused"}), \
             patch.object(loop, "FormalGate", RejectGate), \
             patch.object(loop, "Harness", self.FakeHarness), \
             patch.object(sys, "argv", ["dgm_loop.py", "task", "1"]):
            with self.assertRaises(formal.GateError):
                loop.main()
        self.assertEqual(self.FakeHarness.instances, [])

    def test_default_flow_unchanged_without_gate(self):
        self.FakeHarness.instances.clear()
        with patch.dict(os.environ, {"GRAFF_DGM_FORMAL_PIN": ""}), \
             patch.object(loop, "Harness", self.FakeHarness), \
             patch.object(loop, "load_archive", return_value=({}, {}, {})), \
             patch.object(loop, "judge", return_value=(0.8, "heldout")), \
             patch.object(sys, "argv", ["dgm_loop.py", "task", "1"]):
            del os.environ["GRAFF_DGM_FORMAL_PIN"]
            loop.main()
        harness = self.FakeHarness.instances[0]
        self.assertEqual(len(harness.calls), 2)
        self.assertEqual(len(harness.scores), 1)
        self.assertEqual(harness.scores[0][1]["judge_id"], "replay-v1")
        self.assertTrue(harness.closed)

    def test_opt_in_loop_records_evidence_and_pinned_routes(self):
        self.FakeHarness.instances.clear()
        gate = formal.FormalGate(self.pin, checker=lambda: "a" * 64)
        with patch.dict(os.environ, {"GRAFF_DGM_FORMAL_PIN": str(self.pin)}), \
             patch.object(loop, "FormalGate", lambda _: gate), \
             patch.object(loop, "Harness", self.FakeHarness), \
             patch.object(loop, "load_archive", return_value=({}, {}, {})), \
             patch.object(loop, "judge", return_value=(0.9, gate.pin["heldout_hash"])), \
             patch.object(sys, "argv", ["dgm_loop.py", "task", "1"]):
            loop.main()
        harness = self.FakeHarness.instances[0]
        self.assertEqual(harness.kwargs["binary"], str((self.root / "graff").resolve()))
        self.assertEqual(harness.kwargs["model"], "codex/primary")
        self.assertEqual(harness.kwargs["env"]["GRAFF_EVAL_MODEL"], "codex/replay")
        self.assertEqual(len(harness.scores), 1)
        score = harness.scores[0][1]
        self.assertEqual(score["judge_id"], "replay-v1+formal-v1")
        self.assertEqual(score["eval_set_hash"], gate.pin["heldout_hash"])
        self.assertTrue((gate.receipts / ("score-" + score["artifact_sha"] + ".json")).is_file())
        self.assertTrue(harness.closed)

    def test_drift_during_candidate_execution_prevents_score(self):
        self.FakeHarness.instances.clear()
        gate = formal.FormalGate(self.pin, checker=lambda: "a" * 64)
        target = self.pin.parent / "bundle" / "formal" / "AsyncTools.tla"
        class MutatingHarness(self.FakeHarness):
            def ask(self, prompt):
                result = super().ask(prompt)
                if len(self.calls) == 2:
                    target.write_text("changed during child report")
                return result
        with patch.dict(os.environ, {"GRAFF_DGM_FORMAL_PIN": str(self.pin)}), \
             patch.object(loop, "FormalGate", lambda _: gate), \
             patch.object(loop, "Harness", MutatingHarness), \
             patch.object(loop, "load_archive", return_value=({}, {}, {})), \
             patch.object(loop, "judge", return_value=(0.9, gate.pin["heldout_hash"])), \
             patch.object(sys, "argv", ["dgm_loop.py", "task", "1"]):
            with self.assertRaises(formal.GateError):
                loop.main()
        harness = self.FakeHarness.instances[0]
        self.assertEqual(harness.scores, [])
        self.assertTrue(harness.closed)


if __name__ == "__main__":
    unittest.main()
