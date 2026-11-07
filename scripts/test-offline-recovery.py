#!/usr/bin/env python3
"""A failed connection must not swallow the same prompt after reconnecting.

Uses the retry fixture's loopback server, fake credentials and isolated HOME.
No real network outage, credentials, or model service is needed.
"""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('retry_fixture', REPO / 'scripts/test-retry-cancellation.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class Client(fixture.Client):
    def until(self, predicate, timeout=30):
        return super().until(predicate, timeout=timeout)


def exercise(binary, mode, reload_saved=False):
    with tempfile.TemporaryDirectory(prefix='graff-offline-recovery-') as temp:
        model = fixture.Model('transport')
        client = None
        try:
            root = Path(temp)
            client = Client(binary, root, model, mode)
            identifier = client.begin()
            if mode == 'json':
                failed = client.until(lambda event: event.get('type') == 'error', timeout=30)
            elif mode == 'acp2':
                failed = client.until(lambda event: event.get('params', {}).get('update', {}).get('stopReason') == '_error', timeout=30)
            else:
                failed = client.until(lambda event: event.get('id') == identifier, timeout=30)
                assert 'error' in failed, failed
            assert 'network error:' in json.dumps(failed), failed
            assert client.proc.poll() is None, 'connection failure killed the session'
            before = len(model.requests())
            assert before > 1, 'transient connection retries were bypassed'
            if reload_saved:
                saved = list((root / '.graff/sessions').glob('*.session.json'))
                assert len(saved) == 1, saved
                name = saved[0].name.removesuffix('.session.json')
                loaded = client.call('session/load', {'sessionId': name, 'cwd': str(root), 'mcpServers': []})
                assert 'result' in loaded, loaded
                client.sid = name
            model.recover()
            followup = client.begin()  # Deliberately identical to the failed prompt.
            client.finish(followup)
            assert len(model.requests()) == before + 1, 'reconnected prompt was lost or replayed'
            assert client.proc.poll() is None, 'session exited after reconnect'
            print(f'PASS {mode}/' + ('reload' if reload_saved else 'live') + ': same prompt recovers after exhausted connection retries', flush=True)
        except BaseException:
            stderr = Path(temp) / 'stderr'
            if stderr.exists():
                print(stderr.read_text()[-2000:], file=sys.stderr)
            raise
        finally:
            if client:
                client.close()
            model.close()


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / 'zig-out/bin/graff').resolve()
    modes = sys.argv[2:] or ('acp1', 'acp2', 'json')
    for mode in modes:
        exercise(binary, mode)
        if mode == 'acp1':  # The v2 draft does not advertise session/load.
            exercise(binary, mode, reload_saved=True)


if __name__ == '__main__':
    main()
