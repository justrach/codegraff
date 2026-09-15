#!/usr/bin/env python3
"""Cancel a pending publication review and reuse the same JSON session."""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts/eval'))
from github_fixture import prepare, prepare_review
from mock_model import ScriptedModel


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT/'zig-out/bin/graff')
    parser.add_argument('--output', type=Path, default=ROOT/'zig-out/pr-review-cancel')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    entered, release = threading.Event(), threading.Event()
    class DelayedReview(ScriptedModel):
        def next_reply(self, body):
            reply = super().next_reply(body)
            if len(self.requests) == 3:
                assert 'committed_inputs' in json.dumps(body), 'Third request must be the actual review'
                entered.set()
                assert release.wait(30), 'Fixture review was never released'
            return reply
    model = DelayedReview([
        {'tool':'bash','arguments':{'command':'python3 -m unittest test_value -v'}},
        {'tool':'bash','arguments':{'command':'gh pr create --base fixture-base --title fixture --body-file notes.md'}},
        {'text':json.dumps({'verdict':'supported','reason':'Controlled delayed review.'})},
        {'text':'after-review-cancel-ok'},
    ])
    with tempfile.TemporaryDirectory(prefix='graff-review-cancel-') as tmp:
        work = Path(tmp)
        env = {k:v for k,v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=tmp, LMSTUDIO_API_KEY='local', GRAFF_FLEET='off', GRAFF_NO_TELEMETRY='1',
                   GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1', PYTHONDONTWRITEBYTECODE='1')
        prepare(work, env, {'checks':'SUCCESS'})
        (work/'test_value.py').write_text('import unittest\nclass ValueTest(unittest.TestCase):\n def test_value(self): self.assertEqual(2+2,4)\n')
        (work/'notes.md').write_text('Add an arithmetic fixture test.\nLocal: `python3 -m unittest test_value -v` passed.\nRemote: passed.\n')
        prepare_review(work, ['test_value.py','notes.md'])
        model.start(1234)
        proc = None
        seen = []
        try:
            with (args.output/'stderr.log').open('w') as err:
                proc = subprocess.Popen([str(args.binary.resolve()),'--json','--old','--yolo','--model','lmstudio'],
                    cwd=work, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True)
                events = queue.Queue()
                def reader():
                    for line in proc.stdout:
                        try: events.put(json.loads(line))
                        except ValueError: pass
                threading.Thread(target=reader, daemon=True).start()
                def send(payload):
                    proc.stdin.write(json.dumps(payload)+'\n')
                    proc.stdin.flush()
                def until(predicate):
                    deadline = time.monotonic()+10
                    while time.monotonic()<deadline:
                        event = events.get(timeout=max(.01,deadline-time.monotonic()))
                        seen.append(event)
                        if predicate(event): return event
                    raise AssertionError('Missing expected session event')
                send({'type':'user','text':'Run the local publication fixture.'})
                assert entered.wait(20), 'Harness never entered publication review'
                send({'type':'cancel'})
                until(lambda e:e.get('type')=='error' and e.get('message')=='turn cancelled')
                assert not (work/'mutations.jsonl').exists(), 'Cancelled review must never publish'
                release.set()
                send({'type':'user','text':'Confirm this session still works.'})
                turn = until(lambda e:e.get('type')=='turn')
                assert turn.get('text')=='after-review-cancel-ok', turn
                assert len(model.requests)==4, 'Cancellation must not retry the review'
                assert not (work/'mutations.jsonl').exists(), 'Late supported result must not publish'
                proc.stdin.close()
                assert proc.wait(timeout=10)==0
            print('PASS cancelled pending claim review: no publication; late approval ignored; same session reused')
        finally:
            release.set()
            if proc and proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            model.stop()
            (args.output/'events.json').write_text(json.dumps(seen,indent=2))
            (args.output/'requests.json').write_text(json.dumps(model.requests,indent=2))
            for folder in ('traces','trajectories'):
                source=work/'.graff'/folder
                if source.exists(): shutil.copytree(source,args.output/folder,dirs_exist_ok=True)


if __name__=='__main__':
    main()
