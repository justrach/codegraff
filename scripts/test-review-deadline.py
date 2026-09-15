#!/usr/bin/env python3
"""A review deadline interrupts a stalled request without cancelling later turns."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time

spec = importlib.util.spec_from_file_location('review_fixture', Path(__file__).with_name('test-review-mode.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
original_environment = fixture.environment


def environment(tmp, port):
    env = original_environment(tmp, port)
    env['GRAFF_REVIEW_MAX_SECONDS'] = '1'
    return env


fixture.environment = environment
release = threading.Event()


def responses(request):
    if request.ordinal == 1:
        release.wait(8)
        return fixture.message('This late review response must not complete the review.', 1)
    if request.ordinal in (2, 4):
        time.sleep(1.2)
    return fixture.message('Follow-up remains usable.', request.ordinal)


def main():
    evidence = Path(os.environ['GRAFF_REVIEW_EVIDENCE']) if os.environ.get('GRAFF_REVIEW_EVIDENCE') else None
    with tempfile.TemporaryDirectory(prefix='graff-review-deadline-') as temp:
        mock = fixture.CodexMock(events_for_request=responses)
        port = mock.start()
        proc = fixture.start_graff(temp, port)
        turns = []
        try:
            started = time.monotonic()
            events = fixture.send(proc, {'type': 'review', 'text': 'Review the current workspace.'})
            elapsed = time.monotonic()-started
            turns.append(events)
            assert elapsed < 4, f'deadline failed to interrupt stalled model request: {elapsed:.2f}s'
            assert events[-1]['type'] == 'error', events[-1]
            assert 'wall-time limit' in json.dumps(events[-1]), events[-1]
            assert not any(e.get('type') == 'turn' and e.get('complete') for e in events), events
            release.set()
            for kind in ('user', 'review', 'user'):
                events = fixture.send(proc, {'type': kind, 'text': 'Read-only follow-up.'})
                turns.append(events)
                assert events[-1]['type'] == 'turn', events[-1]
                assert events[-1]['text'] == 'Follow-up remains usable.', events[-1]
            print(f'PASS review deadline interrupted stalled request in {elapsed:.2f}s; three later turns survived')
        finally:
            release.set()
            fixture.close(proc, 'review deadline')
            mock.stop()
            if evidence:
                import shutil
                evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
                (evidence/'turns.json').write_text(json.dumps(turns, indent=2))
                (evidence/'requests.json').write_text(json.dumps([r.body for r in mock.recorded_requests()], indent=2))
                for name in ('traces', 'trajectories', 'sessions'):
                    source = Path(temp)/'.graff'/name
                    if source.exists(): shutil.copytree(source, evidence/name, dirs_exist_ok=True)


if __name__ == '__main__':
    main()
