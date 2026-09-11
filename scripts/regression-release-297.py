#!/usr/bin/env python3
"""Offline production-dispatch regressions for v0.0.297. Never contacts GitHub.

Uses an isolated home/repository, a scripted local model and an argv-recording
stub gh. Listener checks start and stop only this script's own process group.
"""
import argparse
import json
import concurrent.futures
import threading
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))
from mock_model import ScriptedModel

GH = r'''
import json, pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parent.parent
state=json.loads((root/'gh-state.json').read_text())
args=sys.argv[1:]
with (root/'gh-argv.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
head=subprocess.check_output(['GIT_EXE','rev-parse','HEAD'],cwd=root,text=True).strip()
if args[:2]==['run','list']:
    if state.get('unavailable'):sys.exit(1)
    sha=args[args.index('--commit')+1]
    status=state.get('runs','success') if sha==state['initial_head'] else state.get('new_runs','failure')
    if status=='malformed': print('invalid');sys.exit()
    if status=='none': print('[]');sys.exit()
    print(json.dumps([{'status':'queued' if status=='pending' else 'completed','conclusion':None if status=='pending' else status}]))
elif args[:1]==['api']:
    print(state.get('remote_head', head))
elif args[:2]==['pr','view']:
    remote=state.get('remote_head',head)
    status=state.get('checks','PENDING')
    checks=[] if status=='NONE' else [{'state':status}]
    print(json.dumps({'headRefOid':remote,'isDraft':state.get('draft',False),'body':'## Verification\nLocal tests passed.','statusCheckRollup':checks}))
elif args[:2] in (['pr','create'],['pr','ready']):
    with (root/'mutations.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
    if '--draft' in args:state['draft']=True
    if args[:2]==['pr','ready']:state['draft']=False
    (root/'gh-state.json').write_text(json.dumps(state))
    print('https://example.invalid/pull/1')
else: sys.exit(88)
'''


def tool(command):
    return {"tool": "bash", "arguments": {"command": command}}


def completion(text="Verification complete."):
    return {"tool": "attempt_completion", "arguments": {"result": text}}


def run_case(graff, name, script, state=None, expected_mutations=0, refused=0, expected_final=None, resume_check=False):
    with tempfile.TemporaryDirectory(prefix="graff-297-") as temp:
        work = Path(temp)
        (work / "bin").mkdir()
        gh = work / "bin" / "gh"
        gh.write_text(f"#!{sys.executable}\n" + GH.replace("GIT_EXE", shutil.which("git")))
        gh.chmod(0o755)
        subprocess.run(["git", "init", "-q", "-b", "fixture"], cwd=work, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"], cwd=work, check=True)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=work, text=True).strip()
        fixture = dict(initial_head=head, **(state or {}))
        if fixture.get("remote_head") == "initial": fixture["remote_head"] = head
        (work / "gh-state.json").write_text(json.dumps(fixture))
        (work / "notes.md").write_text("Fix the behavior.\n\n## Verification\nLocal regression passed.\n")
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
        env.update(HOME=temp, PATH=str(work / "bin") + os.pathsep + os.environ["PATH"],
                   LMSTUDIO_API_KEY="local", GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off",
                   GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1", NO_COLOR="1")
        model = ScriptedModel(script)
        model.start(1234)
        try:
            done = subprocess.run([str(graff), "--json", "--yolo", "--old", "--model", "lmstudio"],
                                  cwd=work, env=env, text=True, capture_output=True, timeout=100,
                                  input=json.dumps({"type": "user", "text": "Run the scripted publication regression in this fixture repository."}) + "\n")
            assert done.returncode == 0, (name, done.stderr[-2000:])
            events = [json.loads(line) for line in done.stdout.splitlines() if line.startswith('{')]
            mutations = (work / "mutations.jsonl").read_text().splitlines() if (work / "mutations.jsonl").exists() else []
            assert len(mutations) == expected_mutations, (name, mutations, events)
            messages = json.dumps(model.requests)
            assert messages.count("completion deferred: current-head PR verification") >= refused, (name, messages[-8000:])
            if expected_final:
                assert any(expected_final in e.get("text", "") for e in events if e.get("type") == "turn"), (name, done.stdout[-4000:])
                assert any(e.get("type") == "tool_call_finished" and e.get("name") == "attempt_completion" and not e.get("is_error") for e in events), name
            if resume_check:
                sessions = list((work / ".graff/sessions").glob("*.session.json"))
                assert sessions, "fixture session was not persisted"
                saved = next((p for p in sessions if p.name != "last.session.json"), sessions[0])
                model.script.extend([completion("Resumed verification complete."), {"text": "CI is still pending after resume."}])
                resumed = subprocess.run([str(graff), "--json", "--yolo", "--old", "--model", "lmstudio", "--resume", saved.name.removesuffix(".session.json")],
                                         cwd=work, env=env, text=True, capture_output=True, timeout=100,
                                         input=json.dumps({"type": "user", "text": "Resume the PR task and check completion."}) + "\n")
                assert resumed.returncode == 0, resumed.stderr[-2000:]
                latest_tool = next(m for m in reversed(model.requests[-1]["messages"]) if m.get("role") == "tool")
                assert "completion deferred: current-head PR verification" in latest_tool["content"], latest_tool
            print(f"PASS {name}: {len(mutations)} publication(s), expected completion gate checked", flush=True)
        finally:
            model.stop()


def stream_and_mcp(graff):
    with tempfile.TemporaryDirectory(prefix="graff-297-stream-") as temp:
        work = Path(temp)
        server = work / "slow_mcp.py"
        server.write_text("""import json, pathlib, sys, time
for line in sys.stdin:
    try: request=json.loads(line)
    except ValueError: continue
    if 'id' not in request: continue
    deadline=time.monotonic()+25
    while not pathlib.Path('second-native').exists() and time.monotonic()<deadline:time.sleep(.02)
    method=request.get('method')
    result={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'fixture','version':'1'}} if method=='initialize' else {'tools':[]} if method=='tools/list' else {}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
""")
        (work / ".mcp.json").write_text(json.dumps({"mcpServers": {"withheld": {"command": sys.executable, "args": [str(server)]}}}))
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
        env.update(HOME=temp, LMSTUDIO_API_KEY="local", GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off",
                   GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1", GRAFF_MCP_PROBE="0", NO_COLOR="1")
        raw = "Read the docs\ue200cite\ue202turn0search0\ue202turn1search2\ue201 today."
        class TimedModel(ScriptedModel):
            def next_reply(self, body):
                self.times.append(time.monotonic())
                return super().next_reply(body)
        model = TimedModel([tool("printf first > first-native"), tool("printf second > second-native"),
                            dict(completion(raw), argument_chunk_size=1)])
        model.times = []
        model.start(1234)
        try:
            done = subprocess.run([str(graff), "--yolo", "--old", "--model", "lmstudio", "-p", "Run the scripted native tool fixture."],
                                  cwd=work, env=env, text=True, capture_output=True, timeout=45)
            assert done.returncode == 0, done.stderr[-3000:]
            assert (work / "first-native").exists() and (work / "second-native").exists(), done.stderr[-3000:]
            assert model.times[1] - model.times[0] < 5, model.times
            output = done.stdout + done.stderr
            assert "Read the docs today." in output, output[-4000:]
            assert all(mark not in output for mark in ("\ue200", "\ue201", "\ue202", "turn0search0", "turn1search2")), output[-4000:]
            print("PASS deferred MCP: second native tool ran before handshake release; fragmented citations stripped", flush=True)
        finally:
            model.stop()


def handoff(graff):
    with tempfile.TemporaryDirectory(prefix="graff-297-handoff-") as temp:
        work = Path(temp)
        (work / "bin").mkdir()
        gh = work / "bin/gh"
        gh.write_text(f"#!{sys.executable}\n" + GH.replace("GIT_EXE", shutil.which("git")))
        gh.chmod(0o755)
        subprocess.run(["git", "init", "-q", "-b", "fixture"], cwd=work, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"], cwd=work, check=True)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=work, text=True).strip()
        (work / "gh-state.json").write_text(json.dumps({"initial_head": head, "checks": "SUCCESS"}))
        (work / "notes.md").write_text("## Verification\nFixture checks passed.\n")
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
        env.update(HOME=temp, PATH=str(work / "bin") + os.pathsep + os.environ["PATH"], LMSTUDIO_API_KEY="local",
                   GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off", GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1", NO_COLOR="1")
        acquired, primed, transferred = (threading.Event() for _ in range(3))
        def peer(action, kind="publication", key="fixture", **extra):
            return {"tool": "peer_message", "arguments": dict(action=action, kind=kind, key=key, **extra)}
        class Peers(ScriptedModel):
            def next_reply(self, body):
                actor = "A" if "fixture-actor-A" in json.dumps(body) else "B"
                with self._lock:
                    self.requests.append(body)
                    step = self.counts[actor]
                    self.counts[actor] += 1
                if actor == "A":
                    if step == 0: return peer("claim")
                    if step == 1:
                        acquired.set()
                        assert primed.wait(35), "peer did not reach foreign claim gate"
                        ledger = json.loads((work / ".graff/artifact-claims.json").read_text())
                        receiver = next(c["session"] for c in ledger if c["key"] == "independent")
                        return peer("handoff", session=receiver)
                    if step == 2:
                        transferred.set()
                        return tool("gh pr create --title fixture --body-file notes.md")
                else:
                    if step == 0:
                        assert acquired.wait(35)
                        return peer("claim", kind="branch", key="independent")
                    if step == 1: return tool("gh pr create --head unrelated --title fixture --body-file notes.md")
                    if step == 2: return tool("gh pr create --title fixture --body-file notes.md")
                    if step == 3:
                        primed.set()
                        assert transferred.wait(35)
                        return tool("gh pr create --title fixture --body-file notes.md")
                return {"text": "Handoff fixture complete."}
        model = Peers([])
        model.counts = {"A": 0, "B": 0}
        model.start(1234)
        def actor(name):
            return subprocess.run([str(graff), "--json", "--yolo", "--old", "--model", "lmstudio"], cwd=work,
                                  env=env, text=True, capture_output=True, timeout=100,
                                  input=json.dumps({"type": "user", "text": "Run fixture-actor-" + name}) + "\n")
        try:
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                one, two = pool.submit(actor, "A"), pool.submit(actor, "B")
                a, b = one.result(), two.result()
            assert a.returncode == b.returncode == 0, (a.stderr[-1000:], b.stderr[-1000:])
            mutations = (work / "mutations.jsonl").read_text().splitlines() if (work / "mutations.jsonl").exists() else []
            assert len(mutations) == 2, (mutations, a.stdout[-4000:], b.stdout[-4000:])
            assert 'artifact claim held' in a.stdout and 'artifact claim held' in b.stdout, (a.stdout[-3000:], b.stdout[-3000:])
            print("PASS two live sessions: independent branch allowed; handoff enables receiver and revokes old owner", flush=True)
        finally:
            model.stop()


def orphan_listener(graff):
    if sys.platform not in ("darwin", "linux"):
        return
    import re
    import signal
    import socket
    with tempfile.TemporaryDirectory(prefix="graff-297-orphan-") as temp:
        work = Path(temp)
        child = work / "listener.py"
        child.write_text("""import json,os,pathlib,socket,time
s=socket.socket();s.bind(('127.0.0.1',0));s.listen()
pathlib.Path('listener.json').write_text(json.dumps({'pid':os.getpid(),'port':s.getsockname()[1]}))
while True: time.sleep(1)
""")
        env = dict(os.environ, HOME=temp, GRAFF_FIXTURE="legacy-listener", GRAFF_NO_TELEMETRY="1")
        subprocess.run([sys.executable, "-c", "import subprocess,sys;subprocess.Popen([sys.executable,'listener.py'],start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)"], cwd=work, env=env, check=True)
        info = work / "listener.json"
        deadline = time.monotonic() + 10
        while not info.exists() and time.monotonic() < deadline: time.sleep(.05)
        state = json.loads(info.read_text())
        pid, port = state['pid'], state['port']
        try:
            listing = subprocess.run([str(graff), "servers", "list"], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            token = re.search(rf"stop-suspect {pid} ([0-9a-f]+-[0-9a-f]+)", listing.stdout)
            assert token, listing.stdout[-3000:]
            bad = subprocess.run([str(graff), "servers", "stop-suspect", str(pid), "stale-token"], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            assert "unverifiable" in bad.stdout, bad.stdout
            with socket.create_connection(('127.0.0.1', port), timeout=2): pass
            stopped = subprocess.run([str(graff), "servers", "stop-suspect", str(pid), token.group(1)], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            assert "legacy listener stop: stopped" in stopped.stdout, stopped.stdout
            try:
                socket.create_connection(('127.0.0.1', port), timeout=.5).close()
                raise AssertionError("listener survived reported stop")
            except OSError: pass
            assert not (work / '.codegraff/jobs').exists(), "suspect was silently adopted"
            print("PASS legacy orphan: discovery, stale-token refusal, identity-bound explicit stop, no adoption", flush=True)
        finally:
            try: os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError: pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", type=Path, default=ROOT / "zig-out/bin/graff")
    args = parser.parse_args()
    orphan_listener(args.graff)
    handoff(args.graff)
    stream_and_mcp(args.graff)
    create = "gh pr create --title fixture --body-file notes.md"
    for bad in ({"runs": "failure"}, {"runs": "pending"}, {"unavailable": True}, {"runs": "malformed"}):
        run_case(args.graff, f"non-draft refuses {bad}", [tool(create), {"text": "Publication blocked."}], bad)
    run_case(args.graff, "body flag cannot turn non-draft into draft", [tool("gh pr create --title fixture --body '--draft'"), {"text": "Blocked."}], {"runs": "failure"})
    run_case(args.graff, "local-only and repeated completion cannot pass PR CI", [tool(create), completion(), completion(), {"text": "CI remains unverified."}], {"runs": "none"}, expected_mutations=1, refused=2, resume_check=True)
    run_case(args.graff, "fresh passing remote head completes", [tool(create), completion()], {"checks": "SUCCESS"}, expected_mutations=1, expected_final="Verification complete.")
    run_case(args.graff, "draft handoff is explicitly unverified", [tool(create + " --draft"), completion("Handing off the draft.")], {"runs": "failure"}, expected_mutations=1, expected_final="Draft handoff")
    commit = "git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -m next"
    run_case(args.graff, "ready refreshes changed head", [tool(create), tool(commit), tool("gh pr ready"), {"text": "New head needs CI."}], {"checks": "FAILURE"}, expected_mutations=1)
    run_case(args.graff, "passing old remote head is not local new head", [tool(create), tool(commit), completion(), {"text": "Push and verify the new head."}], {"checks": "SUCCESS", "remote_head": "initial"}, expected_mutations=1, refused=1)


if __name__ == "__main__":
    main()
