#!/usr/bin/env python3
"""Exercise preview grace through Graff's real background job and loopback listeners."""
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel


LISTENER = """
import json, os, signal, socket, time
from pathlib import Path
def terminate(*_):
    Path('graceful').touch()
    raise SystemExit(0)
signal.signal(signal.SIGTERM, terminate)
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(.2)
    Path('listener.json').write_text(json.dumps({'pid': os.getpid(),
                                                  'port': listener.getsockname()[1]}))
    while True:
        try:
            conn, _ = listener.accept()
            conn.close()
        except socket.timeout:
            pass
        print('preview heartbeat', flush=True)
"""


def is_listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.5):
            return True
    except OSError:
        return False


def run(binary):
    with tempfile.TemporaryDirectory(prefix='graff-preview-expiry-') as home:
        work = Path(home)
        (work / 'listener.py').write_text(LISTENER)
        (work / 'mcp.json').write_text('{"mcpServers":{}}')
        snapshot = work / '.codegraff/preview-consumers.json'
        snapshot.parent.mkdir()
        model = ScriptedModel([
            {'tool': 'bash', 'arguments': {'command': f'exec {shlex.quote(sys.executable)} listener.py',
                                           'run_in_background': True}},
            {'text': 'The preview is running.'},
        ])
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('GRAFF_', 'CODEDB_')) and not k.endswith('_API_KEY')}
        env.update(HOME=home, AI_GATEWAY_API_KEY='local', GRAFF_FLEET='off',
                   GRAFF_MCP_CONFIG=str(work / 'mcp.json'), GRAFF_NO_TELEMETRY='1',
                   GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1', GRAFF_PREVIEW_GRACE_SECS='4',
                   GRAFF_JOB_IDLE_WARN_MINS='0', GRAFF_JOB_IDLE_STOP_MINS='0',
                   GRAFF_VERCEL_URL=f'http://127.0.0.1:{model.start(0)}/v1/chat/completions')
        state = None

        def publish(consumers, duration, should_survive=True):
            deadline = time.monotonic() + duration
            while time.monotonic() < deadline:
                if not is_listening(state['port']):
                    assert not should_survive, f'preview died during {consumers} consumers'
                    return
                temp = snapshot.with_suffix('.tmp')
                temp.write_text(json.dumps({str(state['port']): consumers}))
                temp.replace(snapshot)
                time.sleep(.2)
            assert should_survive, 'managed preview still listens after a continuous empty grace'

        with tempfile.TemporaryFile() as logs:
            proc = subprocess.Popen([binary, '--json', '--yolo', '--old', '--model', 'vercel'],
                                    cwd=home, env=env, stdin=subprocess.PIPE,
                                    stdout=logs, stderr=logs, text=True)
            try:
                proc.stdin.write('{"type":"user","text":"Start the local preview."}\n')
                proc.stdin.flush()
                deadline = time.monotonic() + 15
                while state is None:
                    assert proc.poll() is None and time.monotonic() < deadline, 'preview did not start'
                    try:
                        state = json.loads((work / 'listener.json').read_text())
                    except (FileNotFoundError, json.JSONDecodeError):
                        time.sleep(.05)
                publish(2, 3)  # two consumers respect the running preview
                publish(1, 3)  # one closes
                publish(0, 3)  # a short gap does not exhaust grace
                publish(1, 3)  # reconnect resets grace
                snapshot.unlink()
                time.sleep(3)   # unknown inventory preserves the preview
                assert is_listening(state['port'])
                publish(0, 12, should_survive=False)
                assert (work / 'graceful').exists(), 'preview was not stopped gracefully'
                assert not is_listening(state['port'])
            except Exception:
                logs.seek(0)
                print(logs.read().decode(errors='replace'), file=sys.stderr)
                raise
            finally:
                proc.stdin.close()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
                model.stop()
                if state is not None and is_listening(state['port']):
                    subprocess.run([binary, 'servers', 'stop', str(state['pid'])], cwd=home,
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


if __name__ == '__main__':
    if os.name != 'posix' or shutil.which('lsof') is None:
        print('SKIP preview expiry: POSIX lsof required')
    else:
        run(str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve()))
        print('PASS preview expiry preserves active and unknown consumers and stops after continuous empty grace')
