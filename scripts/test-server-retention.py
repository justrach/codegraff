"""Verify post-exit server retention through actual agent dispatch and sockets."""
import argparse, importlib.util, json, os, socket, sys, tempfile, signal, time, shlex, shutil, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--graff', type=Path, default=root / 'zig-out/bin/graff')
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--gui', action='store_true', help='Also exercise the GUI API replacement path; requires Bun and native app dependencies')
args = parser.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)
graff = args.graff.resolve()
spec = importlib.util.spec_from_file_location('regression', root / 'scripts/regression-release-297.py')
reg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reg)
def run_case(mode):
    global out
    out = args.evidence.resolve() / mode
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='graff-listener-retain-') as temp:
        work = Path(temp)
        (work / 'mcp.json').write_text('{"mcpServers":{}}')
        (work / 'listener.py').write_text("import json,os,socket,time\nfrom pathlib import Path\ns=socket.socket();s.bind(('127.0.0.1',0));s.listen(16)\nPath('listener.json').write_text(json.dumps({'pid':os.getpid(),'port':s.getsockname()[1]}))\nwhile True: time.sleep(1)\n")
        (work / 'ready.py').write_text("import time,json,socket\nfrom pathlib import Path\nfor _ in range(100):\n if Path('listener.json').exists():break\n time.sleep(.05)\ns=json.loads(Path('listener.json').read_text());socket.create_connection(('127.0.0.1',s['port']),timeout=2).close();print('listener ready')\n")
        env = {k: v for (k, v) in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=temp, LMSTUDIO_API_KEY='local', GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1', NO_COLOR='1', GRAFF_JOB_IDLE_WARN_MINS='0', GRAFF_JOB_IDLE_STOP_MINS='1', GRAFF_MCP_CONFIG=str(work / 'mcp.json'))
        model = reg.ScriptedModel([{'tool': 'bash', 'arguments': {'command': shlex.quote(sys.executable) + ' listener.py', 'run_in_background': True}}, reg.tool(shlex.quote(sys.executable) + ' ready.py'), {'text': 'The isolated listener is ready.'}])
        if mode == 'gui':
            model.script.extend([reg.tool(shlex.quote(sys.executable) + ' ready.py'), {'text': 'Still reachable.'}])
        model.start(1234)
        pid = None
        try:
            command = [str(graff), '--json', '--yolo', '--old', '--model', 'lmstudio']
            prompt = json.dumps({'type': 'user', 'text': 'Start the isolated listener and verify readiness.'}) + '\n'
            if mode == 'gui':
                env.update(GRAFF_BIN=str(graff), GRAFF_CWD=str(work), GRAFF_RETENTION_WORKSPACE=str(work), GRAFF_RETENTION_EVIDENCE=str(out))
                command = ['bun', str(root / 'apps/native/scripts/test-server-retention-route.ts')]
            if mode != 'crash':
                done = reg.bounded_run(command, cwd=work, env=env, text=True, capture_output=True, timeout=110, input=prompt)
            else:
                with (out / 'owner-stdout.log').open('w+') as stdout, (out / 'owner-stderr.log').open('w+') as stderr:
                    process = subprocess.Popen(command, cwd=work, env=env, text=True, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr)
                    try:
                        process.stdin.write(prompt)
                        process.stdin.flush()
                        deadline = time.monotonic() + 30
                        while time.monotonic() < deadline:
                            if len(model.requests) >= 3 and (work / 'listener.json').exists():
                                break
                            assert process.poll() is None, 'owner exited before crash fixture'
                            time.sleep(.05)
                        else:
                            raise AssertionError('listener was not ready before crash')
                        process.kill()
                        process.wait(timeout=10)
                        stdout.seek(0); stderr.seek(0)
                        done = subprocess.CompletedProcess(command, 0, stdout.read(), stderr.read())
                    finally:
                        if process.poll() is None:
                            process.kill(); process.wait(timeout=10)
                        process.stdin.close()

            (out / 'retained-events.jsonl').write_text(done.stdout)
            (out / 'retained-stderr.log').write_text(done.stderr)
            (out / 'retained-requests.json').write_text(json.dumps(model.requests, indent=2))
            for folder in ('sessions', 'traces', 'trajectories'):
                if (work / '.graff' / folder).exists():
                    shutil.copytree(work / '.graff' / folder, out / folder, dirs_exist_ok=True)
            state = json.loads((work / 'listener.json').read_text())
            pid = state['pid']
            assert done.returncode == 0, done.stderr
            with socket.create_connection(('127.0.0.1', state['port']), timeout=2):
                pass
            recs = list((work / '.codegraff/jobs').glob('*.json'))
            assert len(recs) == 1, recs
            record = json.loads(recs[0].read_text())
            assert not record['pinned'], record
            assert record['retained'] == (mode != 'crash'), record
            assert record.get('retention_reason') == ('unverified_consumers' if mode != 'crash' else None), record
            (out / 'retained-record.json').write_text(json.dumps(record, indent=2))
            listing = reg.bounded_run([str(graff), 'servers', 'list'], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            (out / 'retained-list.log').write_text(listing.stdout)
            assert str(record['pid']) in listing.stdout, listing.stdout
            if mode != 'crash':
                assert 'consumer visibility unknown' in listing.stdout, listing.stdout
            else:
                row = next(line for line in listing.stdout.splitlines() if line.split() and line.split()[0].lstrip('+') == str(record['pid']))
                assert 'gone' in row, row
            stopped = reg.bounded_run([str(graff), 'servers', 'stop', str(record['pid'])], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            (out / 'retained-stop.log').write_text(stopped.stdout)
            try:
                socket.create_connection(('127.0.0.1', state['port']), timeout=0.5).close()
                raise AssertionError('owned listener survived explicit stop')
            except OSError:
                pass
            (out / 'retained-results.json').write_text(json.dumps({'status': 'passed', 'checks': ['survivor is not falsely marked as a user pin', 'real background listener survives owner session exit when browser visibility unknown', 'ownership record stays discoverable after owner exit', 'explicit verified stop closes listener']}, indent=2))
            print(f'PASS {mode}: owner exit preserves accurate intent; fresh verified stop closes socket')
        finally:
            model.stop()
            if pid:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

for mode in (('normal', 'crash', 'gui') if args.gui else ('normal', 'crash')):
    run_case(mode)
