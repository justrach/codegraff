#!/usr/bin/env python3
"""Offline harness crash/restart regression: stale shell IDs cannot reach new jobs."""
import argparse, json, os, re, shlex, signal, subprocess, sys, tempfile, threading, time
from pathlib import Path
REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts/eval'))
from mock_model import ScriptedModel


def wait_until(fn, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if fn(): return
        time.sleep(.025)
    raise AssertionError('fixture deadline expired')


def tool_text(body):
    return [m.get('content', '') for m in body.get('messages', []) if m.get('role') == 'tool']


def rejected(text):
    # Historical records may say interrupted; unknown handles must fail closed.
    return bool(re.search(r'no background job|unknown (?:background )?job|interrupted|stale (?:shell )?(?:job|handle)', text, re.I))


def job_id(text):
    found = re.search(r'\[job (\d+) started:', text)
    if not found: raise AssertionError(f'no started handle in {text[:500]!r}')
    return int(found.group(1))


class Model(ScriptedModel):
    def __init__(self, directory, name, old=None):
        super().__init__([])
        self.directory, self.name, self.old = directory, name, old
        self.ready, self.release = threading.Event(), threading.Event()
        self.handle, self.error, self.checked = None, None, {}

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            n = len(self.requests)
        try:
            if n == 1:
                command = 'exec ' + shlex.join([sys.executable, str(self.directory / 'child.py'), str(self.directory), self.name])
                return {'tool': 'shell', 'arguments': {'action': 'run', 'command': command, 'run_in_background': True}}
            results = tool_text(body)
            if n == 2:
                self.handle = job_id(results[-1])
                wait_until(lambda: (self.directory / (self.name + '.heartbeat')).exists())
                time.sleep(.15)
                self.ready.set()
                if self.old is None:
                    self.release.wait(20)
                    return {'text': 'A finished'}
                return {'tool': 'bash_output', 'arguments': {'id': self.old, 'wait_ms': 0}}
            if n == 3:
                self.checked['stale_output'] = results[-1]
                return {'tool': 'bash_kill', 'arguments': {'id': self.old}}
            if n == 4:
                self.checked['stale_kill'] = results[-1]
                heartbeat = self.directory / 'B.heartbeat'
                first = heartbeat.stat().st_size
                time.sleep(.35)
                self.checked['b_alive_after_stale_kill'] = heartbeat.stat().st_size > first
                self.checked['output_rejected'] = rejected(self.checked['stale_output'])
                self.checked['kill_rejected'] = rejected(self.checked['stale_kill'])
                self.checked['b_output_disclosed'] = 'ONLY-B-' in self.checked['stale_output']
                return {'text': 'isolation checked'}
            return {'text': 'done'}
        except Exception as exc:
            self.error = repr(exc)
            self.ready.set()
            return {'text': 'fixture error'}


def cleanup_child(directory, name):
    identity = directory / (name + '.identity')
    if not identity.exists(): return
    record = json.loads(identity.read_text())
    pid = record['pid']
    try:
        cmd = subprocess.check_output(['ps', '-p', str(pid), '-o', 'command='], text=True).strip()
        # Signal only a currently verified child launched from this private directory.
        if str(directory / 'child.py') not in cmd: return
        if os.getpgid(pid) != record['pgid'] or record['pgid'] != pid:
            raise AssertionError('unexpected child process group; refusing cleanup signal')
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, subprocess.CalledProcessError): pass


def start(binary, directory, model):
    port = model.start(0)
    env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
    env.update(HOME=str(directory / 'home'), AI_GATEWAY_API_KEY='local', GRAFF_FLEET='off',
               GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions', GRAFF_NO_TELEMETRY='1',
               GRAFF_NO_SMOLIFY='1', GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
    out = open(directory / (model.name + '.stdout'), 'w')
    err = open(directory / (model.name + '.stderr'), 'w')
    proc = subprocess.Popen([str(binary), '--json', '--yolo', '--old', '--no-lean', '--max-model-calls', '6', '--model', 'vercel'],
                            cwd=directory, env=env, stdin=subprocess.PIPE, stdout=out, stderr=err, text=True, start_new_session=True)
    proc.stdin.write(json.dumps({'type': 'user', 'text': 'Run the scripted shell job and handle checks.'}) + '\n')
    proc.stdin.flush()
    return proc, out, err


def run(binary, expect):
    directory = Path(tempfile.mkdtemp(prefix='graff-shell-restart-'))
    os.chmod(directory, 0o700)
    (directory / 'home').mkdir(mode=0o700)
    (directory / 'child.py').write_text('''import json, os, sys, time
from pathlib import Path
root, name = Path(sys.argv[1]), sys.argv[2]
(root / (name + '.identity')).write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp()}))
print('ONLY-' + name + '-PRIVATE-JOB-OUTPUT', flush=True)
for _ in range(1200):
    with (root / (name + '.heartbeat')).open('a') as f: f.write('.')
    time.sleep(.05)
''')
    running = []
    models = []
    try:
        a = Model(directory, 'A'); models.append(a)
        process_a, out_a, err_a = start(binary, directory, a); running.append((process_a, out_a, err_a))
        assert a.ready.wait(20), 'A did not return a background handle'
        assert not a.error, a.error
        assert a.handle is not None
        process_a.kill(); process_a.wait(timeout=5)  # abrupt harness crash, no shutdown cleanup
        a.release.set()
        cleanup_child(directory, 'A')
        b = Model(directory, 'B', a.handle); models.append(b)
        process_b, out_b, err_b = start(binary, directory, b); running.append((process_b, out_b, err_b))
        wait_until(lambda: bool(b.checked.get('stale_kill')) or b.error is not None, 25)
        wait_until(lambda: 'b_alive_after_stale_kill' in b.checked or b.error is not None, 5)
        assert not b.error, b.error
        passed = bool(b.handle != a.handle and b.checked['output_rejected'] and b.checked['kill_rejected'] and
                      b.checked['b_alive_after_stale_kill'] and not b.checked['b_output_disclosed'])
        report = dict(binary=str(binary), old_handle=a.handle, new_handle=b.handle, passed=passed, **b.checked)
        (directory / 'receipt.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(dict(directory=str(directory), **report), indent=2))
        assert passed == (expect == 'pass'), f'expected {expect}, observed {passed}'
    finally:
        for model in models: model.release.set()
        for process, out, err in running:
            if process.poll() is None: process.kill()
            process.wait(timeout=5)
            out.close(); err.close()
        for name in ('A', 'B'): cleanup_child(directory, name)
        for model in models: model.stop()


if __name__ == '__main__':
    if os.name != 'posix':
        print('SKIP shell crash/restart: POSIX process-group fixture')
        sys.exit(0)
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path, nargs='?', default=REPO / 'zig-out/bin/graff')
    parser.add_argument('--expect', choices=['pass', 'fail'], default='pass')
    args = parser.parse_args()
    run(args.binary.resolve(), args.expect)
