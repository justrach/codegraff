from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import worker_matrix as runner
import worker_matrix_measure as metrics

ROOT = {"provider": "fixture-provider", "model": "root-fixture"}
WORKER = {"provider": "fixture-provider", "model": "worker-fixture"}
RATES = {"input": "2", "cached": "0.2", "write": "2.5", "write_1h": "4",
         "output": "10", "max_input": 200000, "source": "Synthetic test rates"}


def evidence(worker=False):
    usage = [{"ev": "usage", "from_sub": False, "agent": "main", **ROOT,
              "input_tokens": 100, "cache_read_tokens": 50, "cache_write_tokens": 20,
              "output_tokens": 10}]
    if worker:
        usage += [{"ev": "usage", "from_sub": True, "agent": "child", **WORKER,
                   "input_tokens": 20, "output_tokens": 2}]
    terminal = {"type": "turn", "complete": True, "usage_complete": True,
                "input_tokens": sum(r["input_tokens"] for r in usage),
                "output_tokens": sum(r["output_tokens"] for r in usage),
                "api_calls": len(usage), "missing_usage_calls": 0,
                "unreported_failed_attempts": 0, "unpriced_calls": len(usage),
                "subscription_calls": 0, "cost_usd": 0}
    events = [terminal]
    if worker:
        events += [{"type": "agent_route", "provider": WORKER["provider"],
                    "resolved_model": WORKER["model"]}, {"type": "agent_usage"}]
    return events, usage + [{"ev": "api", "is_error": False} for _ in usage]


class Measurements(unittest.TestCase):
    def test_complete_tokens_do_not_make_unpriced_calls_free(self):
        events, traces = evidence()
        result = metrics.measure(events, traces, {"root": ROOT}, 1)
        self.assertTrue(result["token_usage_complete"])
        self.assertFalse(result["native_cost_complete"])
        self.assertIsNone(result["native_full_cost_usd"])
        self.assertEqual(result["native_known_subtotal_usd"], 0)
        self.assertIsNone(result["api_equivalent_estimate_usd"])

    def test_explicit_rates_split_roles_and_cache_writes(self):
        events, traces = evidence(True)
        arm = {"root": ROOT, "worker": WORKER, "prices": {"root": RATES, "worker": RATES}}
        result = metrics.measure(events, traces, arm, 1)
        self.assertTrue(result["routing_ok"])
        self.assertTrue(result["delegation_ok"])
        self.assertEqual(result["estimated_role_costs_usd"]["root"], "0.00022")
        self.assertEqual(result["api_equivalent_estimate_usd"], "0.00028")
        traces[0]["cache_ttl"] = "1h"
        self.assertEqual(metrics.measure(events, traces, arm, 1)["estimated_role_costs_usd"]["root"], "0.00025")

    def test_missing_failed_or_malformed_usage_is_unknown(self):
        for field in ("missing_usage_calls", "unreported_failed_attempts"):
            events, traces = evidence()
            events[0][field] = 1
            result = metrics.measure(events, traces, {"root": ROOT, "prices": {"root": RATES}}, 1)
            self.assertFalse(result["token_usage_complete"])
            self.assertIsNone(result["api_equivalent_estimate_usd"])
        events, traces = evidence()
        self.assertFalse(metrics.measure(events, traces, {"root": ROOT}, 1, malformed=1)["token_usage_complete"])
        traces[0]["input_tokens"] = -1
        self.assertFalse(metrics.measure(events, traces, {"root": ROOT}, 1)["token_usage_complete"])

    def test_missing_or_boolean_accounting_counters_do_not_qualify(self):
        events, traces = evidence()
        events[0]["unpriced_calls"] = True
        self.assertFalse(metrics.measure(events, traces, {"root": ROOT}, 1)["token_usage_complete"])
        del events[0]["unpriced_calls"]
        self.assertFalse(metrics.measure(events, traces, {"root": ROOT}, 1)["token_usage_complete"])

    def test_subscription_and_wrong_routes_never_get_full_native_cost(self):
        events, traces = evidence()
        events[0].update(unpriced_calls=0, subscription_calls=1)
        self.assertIsNone(metrics.measure(events, traces, {"root": ROOT}, 1)["native_full_cost_usd"])
        traces[0]["provider"] = "wrong-fixture"
        self.assertFalse(metrics.measure(events, traces, {"root": ROOT}, 1)["routing_ok"])

    def test_missing_workers_cannot_qualify_as_a_team(self):
        events, traces = evidence(True)
        arm = {"root": ROOT, "worker": WORKER}
        self.assertFalse(metrics.measure(events, traces, arm, 3)["delegation_ok"])
        events.pop()
        self.assertFalse(metrics.measure(events, traces, arm, 1)["delegation_ok"])
        self.assertFalse(metrics.measure(events, traces, {"root": ROOT}, 1)["routing_ok"])

    def test_request_band_limit_not_aggregate_tokens(self):
        _, traces = evidence()
        rates = {**RATES, "max_input": 100}
        self.assertIsNotNone(metrics.price_rows([traces[0], traces[0]], rates))
        self.assertIsNone(metrics.price_rows([traces[0]], {**rates, "max_input": 99}))

    def test_incomplete_trial_keeps_full_mean_unknown(self):
        trials = [{"task": "fixture", "arm": "solo", "passed": True, "seconds": 1,
                   "native_full_cost_usd": "0.1", "api_equivalent_estimate_usd": "0.2"},
                  {"task": "fixture", "arm": "solo", "passed": False, "seconds": 3,
                   "native_full_cost_usd": None, "api_equivalent_estimate_usd": "0.4"}]
        group = metrics.summarize(trials)[0]
        self.assertEqual(group["passed"], 1)
        self.assertEqual(group["mean_seconds"], 2)
        self.assertIsNone(group["mean_native_full_cost_usd"])
        self.assertEqual(group["mean_api_equivalent_estimate_usd"], "0.3")

    def test_summary_splits_roles_and_includes_failed_trials(self):
        trials = [
            {"task": "fixture", "arm": "team", "passed": passed, "seconds": seconds,
             "native_full_cost_usd": None, "api_equivalent_estimate_usd": total,
             "estimated_role_costs_usd": {"root": root, "worker": worker}}
            for passed, seconds, root, worker, total in (
                (True, 2, "0.1", "0.2", "0.3"),
                (False, 4, "0.3", "0.4", "0.7"))]
        group = metrics.summarize(trials)[0]
        self.assertEqual(group["attempted"], 2)
        self.assertEqual(group["passed"], 1)
        self.assertEqual(group["mean_seconds"], 3)
        self.assertEqual(group["mean_estimated_role_costs_usd"], {"root": "0.2", "worker": "0.3"})
        self.assertEqual(group["mean_api_equivalent_estimate_usd"], "0.5")
        self.assertIsNone(group["mean_native_full_cost_usd"])

    def test_summary_preserves_unknown_roles_and_explicit_solo_zero(self):
        def trial(roles):
            return {"task": "fixture", "arm": "solo", "passed": True, "seconds": 1,
                    "native_full_cost_usd": "0.1", "api_equivalent_estimate_usd": None,
                    "estimated_role_costs_usd": roles}
        for roles in ({}, {"root": None, "worker": None}, {"root": "0.2"}):
            group = metrics.summarize([trial({"root": "0.1", "worker": "0"}), trial(roles)])[0]
            self.assertIsNone(group["mean_estimated_role_costs_usd"]["worker"])
            if roles.get("root") is None:
                self.assertIsNone(group["mean_estimated_role_costs_usd"]["root"])
        group = metrics.summarize([trial({"root": "0.1", "worker": "0"})])[0]
        self.assertEqual(group["mean_estimated_role_costs_usd"], {"root": "0.1", "worker": "0"})
        legacy = trial({})
        del legacy["estimated_role_costs_usd"]
        self.assertEqual(metrics.summarize([legacy])[0]["mean_estimated_role_costs_usd"],
                         {"root": None, "worker": None})

    def test_saved_summary_never_executes_or_changes_results(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "results.json"
            trials = [{"task": "fixture", "arm": "solo", "passed": True, "seconds": 2,
                       "native_full_cost_usd": None, "api_equivalent_estimate_usd": "0.1",
                       "estimated_role_costs_usd": {"root": "0.1", "worker": "0"}}]
            original = json.dumps(trials)
            path.write_text(original)
            output = io.StringIO()
            with patch("sys.argv", ["worker_matrix.py", "--summarize", temp]), \
                    patch.object(runner, "batch", side_effect=AssertionError("No execution")), \
                    patch.object(runner, "prepare", side_effect=AssertionError("No preparation")), \
                    patch.object(runner.subprocess, "Popen", side_effect=AssertionError("No process")), \
                    redirect_stdout(output):
                runner.main()
            report = json.loads(output.getvalue())
            self.assertEqual(report["groups"][0]["mean_estimated_role_costs_usd"],
                             {"root": "0.1", "worker": "0"})
            self.assertEqual(path.read_text(), original)
            self.assertEqual(list(Path(temp).iterdir()), [path])

    def test_saved_summary_rejects_execution_flags(self):
        for flags in (["--run", "unused"], ["--manifest", "unused"],
                      ["--binary", "unused"], ["--output-root", "unused"]):
            with patch("sys.argv", ["worker_matrix.py", "--summarize", "unused", *flags]), \
                    patch.object(runner, "batch", side_effect=AssertionError("No execution")), \
                    patch.object(runner, "prepare", side_effect=AssertionError("No preparation")), \
                    redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    runner.main()
                self.assertEqual(raised.exception.code, 2)

    def test_two_routes_solo_and_same_route_teams_schedule_eight_trials(self):
        arms = [
            {"id": kind + "-" + label, "root": route,
             **({"worker": route} if kind == "team" else {})}
            for label, route in (("a", ROOT), ("b", WORKER))
            for kind in ("solo", "team")]
        manifest = {"repetitions": 2, "max_model_calls": 8, "max_tool_calls": 20,
                    "cost_stop_usd": "1", "auth_env": [], "auth_files": [],
                    "tasks": [{"team": "sa-fix-three", "solo": "solo-fix-three", "workers": 3}],
                    "arms": arms}
        runner.validate(manifest)
        slots = runner.schedule(manifest)
        self.assertEqual(len(slots), 8)
        self.assertEqual({(r["rep"], r["arm"]) for r in slots},
                         {(rep, arm["id"]) for rep in (1, 2) for arm in arms})
        self.assertTrue(all(r["task"] == "sa-fix-three" for r in slots))
        self.assertEqual([r["arm"] for r in slots[:4]], [a["id"] for a in arms])
        self.assertEqual([r["arm"] for r in slots[4:]], [a["id"] for a in arms[1:] + arms[:1]])
        self.assertTrue(all(a["worker"] == a["root"] for a in arms if "worker" in a))


@unittest.skipUnless(os.name == "posix", "Local process session runner")
class LocalRunner(unittest.TestCase):
    def test_frozen_opt_in_execution_and_no_reruns(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            evals = base / "evals"
            fixture = evals / "fixtures" / "small"
            fixture.mkdir(parents=True)
            (evals / "tasks").mkdir()
            (evals / "hidden").mkdir()
            (fixture / "value.py").write_text("value = 0\n")
            verifier = "from value import value\nassert value == 1\n"
            (fixture / "test_value.py").write_text(verifier)
            (evals / "hidden" / "small.py").write_text(
                "import sys\nsys.path.insert(0, '.')\n" + verifier)
            team = {"id": "team", "suite": "subagents", "files_dir": "fixtures/small",
                    "prompt": "Fix value", "timeout_s": 30,
                    "check": 'python3 test_value.py && python3 "$TASK_ROOT/hidden/small.py"'}
            solo = {**team, "id": "solo", "suite": "subagents-solo", "counterfactual_of": "team"}
            for task in (team, solo):
                (evals / "tasks" / (task["id"] + ".json")).write_text(json.dumps(task))
            binary = base / "stub"
            events, traces = evidence()
            stub = (
                "#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n"
                "sys.stdin.readline()\nPath('value.py').write_text('value = 1\\n')\n"
                "p=Path('.graff/traces');p.mkdir(parents=True)\n"
                f"rows={traces!r}\n"
                "(p/'fixture.jsonl').write_text(''.join(json.dumps(r)+'\\n' for r in rows))\n"
                f"events={events!r}\n"
                "for e in events: print(json.dumps(e))\n")
            binary.write_text(stub)
            binary.chmod(0o700)
            manifest = {"repetitions": 2, "max_model_calls": 8, "max_tool_calls": 20,
                        "cost_stop_usd": "1", "tasks": [{"team": "team", "solo": "solo", "workers": 1}],
                        "arms": [{"id": "solo", "root": ROOT, "prices": {"root": RATES}}]}
            config = base / "config.json"
            config.write_text(json.dumps(manifest))
            output = base / "private"
            with patch.object(runner, "EVALS", evals):
                runner.prepare(config, binary, output)
                self.assertFalse((output / "runs").exists())
                runner.batch(output)
                results = json.loads((output / "results.json").read_text())
                self.assertEqual(len(results), 2)
                self.assertTrue(all(r["passed"] for r in results))
                self.assertTrue(all(r["native_full_cost_usd"] is None for r in results))
                with self.assertRaises(ValueError):
                    runner.batch(output)
                with self.assertRaises(FileExistsError):
                    runner.prepare(config, binary, output)
                for path in output.rglob("*"):
                    want = 0o700 if path.is_dir() or path == output / "graff" else 0o600
                    self.assertEqual(path.stat().st_mode & 0o777, want)

    def test_manifest_rejects_unbounded_calls_and_auth_path_traversal(self):
        manifest = {"repetitions": 1, "max_model_calls": 0, "max_tool_calls": 20,
                    "cost_stop_usd": "1", "tasks": [{"team": "team", "solo": "solo", "workers": 1}],
                    "arms": [{"id": "solo", "root": ROOT}]}
        with self.assertRaises(ValueError):
            runner.validate(manifest)
        with self.assertRaises(ValueError):
            runner.relative("../escape")


if __name__ == "__main__":
    unittest.main()
