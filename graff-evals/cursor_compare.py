#!/usr/bin/env python3
"""Matched, isolated Graff versus native Cursor comparisons (opt-in live spend)."""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def catalog():
    return json.loads((HERE / "cursor_compare_presets.json").read_text())


def select_tasks(data, smoke, requested):
    if requested:
        if smoke or len(set(requested)) != len(requested) or not set(requested) <= set(data["tasks"]):
            raise ValueError("--task requires unique catalog tasks and cannot be combined with --smoke")
        return [task for task in data["tasks"] if task in requested]
    return data["smoke_tasks"] if smoke else data["tasks"]


def private_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def events(stdout):
    rows = []
    for line in stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def cursor_receipt(stdout, expected_label):
    rows = events(stdout)
    labels = sorted({" ".join(r["model"].split()) for r in rows
                     if r.get("type") == "system" and isinstance(r.get("model"), str)})
    finals = [r for r in rows if r.get("type") == "result"]
    final = finals[-1] if finals else {}
    return {"observed_model_labels": labels,
            "routing_ok": labels == [expected_label],
            "native_completion_ok": bool(finals) and final.get("subtype") == "success" and not final.get("is_error"),
            "native_task_duration_s": final.get("duration_ms", 0) / 1000 if isinstance(final.get("duration_ms"), (int, float)) else None}


def graff_receipt(sandbox, provider, model, effort):
    rows = []
    for path in (sandbox / ".graff/traces").glob("*.jsonl"):
        rows.extend(events(path.read_text(errors="replace")))
    api = [r for r in rows if r.get("ev") == "api"]
    roots = [r for r in api if r.get("agent") in ("main", "repl")]
    pairs = sorted({(r["provider"], r["model"]) for r in rows
                    if isinstance(r.get("provider"), str) and isinstance(r.get("model"), str)})
    output = (sandbox / ".eval-stdout.txt").read_text(errors="replace")
    effort_ok = "reasoning effort: " + effort.lower() in output.lower()
    return {"observed_provider_models": pairs,
            "observed_root_models": sorted({r.get("model", "") for r in roots}),
            "trace_api_calls": len(api), "effort_selection_ok": effort_ok,
            "routing_ok": bool(roots) and bool(pairs) and effort_ok
                          and all(r.get("model") == model for r in roots)
                          and all(p == provider for p, _ in pairs),
            "provider_evidence": "trace+isolated-login+explicit-route"}


def access_credentials(provider, args):
    """Only the selected login, never an API-key fallback or refresh token."""
    path = Path(args.codegraff_auth if provider == "codegraff" else args.xai_auth).expanduser()
    data = json.loads(path.read_text())
    if provider == "codegraff":
        if not data.get("api_key"):
            raise ValueError("Codegraff login missing; run graff login codegraff")
        return {"api_key": data["api_key"]}
    if not data.get("access_token"):
        raise ValueError("xAI subscription login missing; run graff login xai")
    expiry = data.get("expires_at")
    if not isinstance(expiry, (int, float)) or expiry < time.time() + 1800:
        raise ValueError("xAI login has less than 30 minutes remaining; refresh the login before starting")
    return {"access_token": data["access_token"], "expires_at": int(expiry)}


def cursor_credentials(path):
    if path:
        data = json.loads(Path(path).expanduser().read_text())
        access = data.get("accessToken")
    elif sys.platform == "darwin":
        # One exact named item; no keychain enumeration or refresh credential.
        result = subprocess.run(["security", "find-generic-password", "-s", "cursor-access-token",
                                 "-a", "cursor-user", "-w"], capture_output=True, text=True)
        access = result.stdout.strip() if result.returncode == 0 else ""
    else:
        raise ValueError("Supply --cursor-auth with a private accessToken snapshot")
    if not access:
        raise ValueError("Cursor access login missing; sign in with agent login")
    # The CLI requires this field but must never rotate the owner's refresh token.
    return {"accessToken": access, "refreshToken": "disabled-for-evaluation"}


def safe_environment(cache):
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "SDKROOT", "DEVELOPER_DIR", "TMPDIR") if k in os.environ}
    env.update(GRAFF_NO_TELEMETRY="1", GRAFF_BEHAVIOR_UPLOAD="off", GRAFF_FLEET="off",
               GRAFF_NO_SMOLIFY="1", NO_COLOR="1", DIRENV_DISABLE="1", NODE_COMPILE_CACHE=str(cache))
    return env


def home_environment(home):
    return {"HOME": str(home), "USERPROFILE": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(home / ".cache"), "CURSOR_CONFIG_DIR": str(home / ".cursor"),
            "AGENT_CLI_CREDENTIAL_STORE": "file"}


def seed_login(home, provider, model, credentials):
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    (home / ".simple-harness-model").write_text(provider + "\n" + model + "\n")
    relative = ".simple-harness-codegraff.json" if provider == "codegraff" else ".xai/credentials/graff-oauth.json"
    private_json(home / relative, credentials)


def cleanup_credentials(root):
    for pattern in ("**/.cursor/auth.json", "**/.simple-harness-codegraff.json", "**/.xai/credentials/graff-oauth.json"):
        for path in root.glob(pattern):
            path.unlink(missing_ok=True)


def configure_runner(runner, preset, root, frozen, agent, credentials, cursor_auth):
    materialize_original = runner.materialize
    harnesses_original = runner.load_harnesses
    parse_original = runner.parse_answer_and_usage
    run_original = runner.one_run

    def materialize(task, sandbox):
        materialize_original(task, sandbox)
        home = Path(sandbox) / ".eval-home"
        if Path(sandbox).name.startswith("graff-"):
            seed_login(home, preset["provider"], preset["models"]["graff"], credentials)
        else:
            private_json(home / ".cursor/auth.json", cursor_auth)
        source = Path(sandbox) / ".mcp.json"
        if source.is_file():
            config = json.loads(source.read_text())
            for spec in config.get("mcpServers", {}).values():
                spec["args"] = [str(Path(sandbox) / arg) if isinstance(arg, str) and (Path(sandbox) / arg).exists() else arg
                                for arg in spec.get("args", [])]
            private_json(Path(sandbox) / ".cursor/mcp.json", config)

    def harnesses():
        graff = copy.deepcopy(harnesses_original()["graff-repl"])
        graff["cmd"][0] = str(frozen)
        graff["stdin"] = "/effort " + preset["effort"] + "\n" + graff["stdin"]
        graff["default_model"] = preset["models"]["graff"]
        graff["model_prefix"] = preset["provider"]
        cursor = {"cmd": [str(agent), "-p", "--model", "{model}", "--output-format", "stream-json",
                           "--trust", "--force", "--approve-mcps", "--workspace", "{sandbox}", "{prompt}"],
                  "answer": "cursor-stream", "default_model": preset["models"]["cursor"]}
        selected = {"graff": graff, "cursor": cursor}
        for harness in selected.values():
            harness.setdefault("env", {}).update(home_environment(Path("{sandbox}/.eval-home")))
            harness["env"]["GRAFF_MCP_CONFIG"] = "{sandbox}/.mcp.json"
        return selected

    def parse(harness, stdout, stderr, sandbox=""):
        if harness["answer"] != "cursor-stream":
            return parse_original(harness, stdout, stderr, sandbox)
        finals = [r for r in events(stdout) if r.get("type") == "result"]
        if not finals:
            return "", {}
        final = finals[-1]
        native = final.get("usage") or {}
        usage = {"native_input_tokens": native.get("inputTokens"), "native_output_tokens": native.get("outputTokens"),
                 "native_cache_read_tokens": native.get("cacheReadTokens"), "native_cache_write_tokens": native.get("cacheWriteTokens"),
                 "api_ms": final.get("duration_api_ms")}
        return str(final.get("result") or "").strip(), usage

    def one_run(hname, harness, task, model, rep, live=False):
        rec = run_original(hname, harness, task, model, rep, live)
        if "wall_s" not in rec:
            return rec
        sandbox = Path(runner.SANDBOX_DIR) / f"{hname}-{task['id']}-r{rep}"
        if hname == "cursor":
            rec.update(cursor_receipt((sandbox / ".eval-stdout.txt").read_text(), preset["cursor_label"]))
            if rec["native_task_duration_s"] is not None:
                rec["outside_native_duration_s"] = rec["wall_s"] - rec["native_task_duration_s"]
        else:
            rec.update(graff_receipt(sandbox, preset["provider"], model, preset["effort"]))
            rec["native_completion_ok"] = rec.get("exit") == 0 and not rec.get("timed_out")
        rec["list_usd"] = None
        rec["list_price_note"] = "Subscription comparison; comparable marginal costs are unknown, not zero"
        rec["comparison_kind"] = "same-named-model, different harness/provider backends"
        rec["outcome_ok"] = bool(rec["outcome_ok"] and rec["routing_ok"] and rec["native_completion_ok"]
                                 and rec.get("exit") == 0 and not rec.get("timed_out"))
        return rec

    runner.materialize, runner.load_harnesses = materialize, harnesses
    runner.parse_answer_and_usage, runner.one_run = parse, one_run
    runner.eval_report.line = lambda r: (f"{'PASS' if r.get('outcome_ok') else 'FAIL'} {r['harness']:6} {r['task']:20} "
                                        f"r{r['rep']} wall={r.get('wall_s')}s artifact={r.get('artifact_ok')} "
                                        f"route={r.get('routing_ok')} exit={r.get('exit')}")
    runner.eval_report.summarize = lambda rows: print("Comparable prices and Cursor model-call counts are unknown.")


def main():
    data = catalog()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preset", choices=sorted(data["presets"]), required=True)
    parser.add_argument("--binary", default=str(REPO / "zig-out/bin/graff"))
    parser.add_argument("--cursor-bin", default="agent")
    parser.add_argument("--cursor-auth", help="private JSON containing accessToken; macOS defaults to one named Keychain item")
    parser.add_argument("--codegraff-auth", default=str(Path.home() / ".simple-harness-codegraff.json"))
    parser.add_argument("--xai-auth", default=str(Path.home() / ".xai/credentials/graff-oauth.json"))
    parser.add_argument("--smoke", action="store_true", help="three fixture pairs, one repetition; excluded from full score")
    parser.add_argument("--task", action="append", help="repeat to select a catalog subset; incompatible with --smoke")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--output-root", help="new private receipts root OUTSIDE every repository; otherwise a private temp directory")
    parser.add_argument("--report-dir", help="optional local summary directory (no native logs or credentials)")
    args = parser.parse_args()
    if args.reps < 1 or args.workers < 1:
        parser.error("--reps and --workers must be positive")
    try:
        tasks = select_tasks(data, args.smoke, args.task)
    except ValueError as error:
        parser.error(str(error))
    preset = data["presets"][args.preset]
    credentials = access_credentials(preset["provider"], args)
    cursor_auth = cursor_credentials(args.cursor_auth)
    root = Path(args.output_root).expanduser().resolve() if args.output_root else Path(tempfile.mkdtemp(prefix="cursor-" + args.preset + "-"))
    if any((p / ".git").exists() for p in (root, *root.parents)):
        parser.error("receipts and sandboxes must be outside repositories")
    if args.output_root:
        root.mkdir(parents=True, mode=0o700, exist_ok=False)
    root.chmod(0o700)
    scripts = root / "scripts"
    scripts.mkdir()
    shutil.copy2(REPO / "scripts/linear_fixture_mcp.py", scripts)
    frozen = root / "graff"
    shutil.copy2(Path(args.binary).resolve(), frozen)
    agent_path = shutil.which(args.cursor_bin)
    if not agent_path:
        raise ValueError("Cursor CLI not found; install agent or supply --cursor-bin")
    agent = Path(agent_path).resolve()
    index = agent.with_name("index.js")
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    version = subprocess.check_output([str(agent), "--version"], text=True).strip()
    env = safe_environment(root / "node-compile-cache")
    preflight = root / "preflight-home"
    seed_login(preflight, preset["provider"], preset["models"]["graff"], credentials)
    env.update(home_environment(preflight))
    env["GRAFF_MCP_CONFIG"] = str(root / "empty-mcp.json")
    private_json(root / "empty-mcp.json", {"mcpServers": {}})
    try:
        route = subprocess.run([str(frozen), "route", preset["provider"] + "/" + preset["models"]["graff"]],
                               env=env, capture_output=True, text=True, check=True, timeout=30).stdout.strip()
        if "auth: OAuth/login" not in route or (preset["provider"] == "xai" and "billing: subscription, flat-rate" not in route):
            raise ValueError("isolated provider route did not confirm the requested login/subscription")
        subprocess.run([str(agent), "--version"], env=env, capture_output=True, check=True, timeout=90)
        meta = {"preset": args.preset, "models": preset["models"], "provider": preset["provider"], "effort": preset["effort"],
                "repetitions": 1 if args.smoke else args.reps, "tasks": tasks, "workers": min(2, args.workers) if args.smoke else args.workers,
                "mode": "smoke" if args.smoke else "subset" if args.task else "full", "graff_sha256": digest(frozen), "build_mode": "caller-supplied binary (frozen)",
                "cursor_version": version, "cursor_index_sha256": digest(index) if index.is_file() else None,
                "comparison_kind": "same named model, different harnesses/provider backends", "isolated_route": route,
                "credentials": "isolated access-only snapshots; no valid refresh tokens, API-key fallback, personal MCP or rules",
                "latency_note": "wall is task process lifetime; first_out includes startup events and is not TTFT",
                "runtime_cache": "Cursor Node compile cache prewarmed once and shared; account/workspace homes isolated",
                "created_at": datetime.now(timezone.utc).isoformat()}
        private_json(root / "metadata.json", meta)
        print("Private comparison root:", root, flush=True)
        import run as runner
        original_env = dict(os.environ)
        os.environ.clear()
        os.environ.update(env)
        try:
            configure_runner(runner, preset, root, frozen, agent, credentials, cursor_auth)
            sys.argv = [str(HERE / "run.py"), "--harness", "graff,cursor", "--suite", "core,mcp", "--reps", str(meta["repetitions"]),
                        "-j", str(meta["workers"]), "--interleave", "--arm", args.preset, "--output-root", str(root / "comparison")]
            for task in tasks:
                sys.argv += ["--task", task]
            runner.main()
        finally:
            os.environ.clear()
            os.environ.update(original_env)
        if index.is_file() and digest(index) != meta["cursor_index_sha256"]:
            raise ValueError("Cursor CLI changed during the comparison")
        from cursor_compare_report import summarize
        report = summarize(root, Path(args.report_dir) if args.report_dir else root / "report")
        if any(report.get("failures", [])):
            return 1
    finally:
        cleanup_credentials(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
