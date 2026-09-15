#!/usr/bin/env python3
"""Exercise a stalled index probe through real bash dispatch, then retry it."""
import argparse
import json
import os
import queue
import threading
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts/eval'))
from mock_model import ScriptedModel
from process_guard import run



def cancelled_run(binary, work, env):
    events=queue.Queue()
    seen=[]
    with (work/'cancel-stderr.log').open('w') as err:
        proc=subprocess.Popen([str(binary.resolve()),'--json','--old','--yolo','--model','lmstudio'],cwd=work,env=env,
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True)
        def reader():
            for line in proc.stdout:
                try:events.put(json.loads(line))
                except ValueError:pass
        threading.Thread(target=reader,daemon=True).start()
        def send(payload):
            proc.stdin.write(json.dumps(payload)+'\n')
            proc.stdin.flush()
        def until(predicate):
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                event=events.get(timeout=max(.01,deadline-time.monotonic()))
                seen.append(event)
                if predicate(event):return event
            raise AssertionError('Missing cancellation/session result')
        try:
            send({'type':'user','text':'Exercise the local source-read guard fixture.'})
            deadline=time.monotonic()+10
            while not (work/'child-pid').exists():
                assert proc.poll() is None and time.monotonic()<deadline,'Probe never started'
                time.sleep(.02)
            send({'type':'cancel'})
            until(lambda e:e.get('type')=='error' and e.get('message')=='turn cancelled')
            send({'type':'user','text':'Retry the local source-read fixture.'})
            turn=until(lambda e:e.get('type')=='turn')
            assert turn.get('text')=='probe fixture completed',turn
            assert not any('fixture_marker' in e.get('text','') for e in seen if e.get('type')=='tool_result'), 'Cancelled read executed'
            proc.stdin.close()
            assert proc.wait(timeout=5)==0
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
    return '\n'.join(json.dumps(e) for e in seen), (work/'cancel-stderr.log').read_text()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,default=ROOT/'zig-out/bin/graff')
    parser.add_argument('--output',type=Path,default=ROOT/'zig-out/codedb-probe-deadline')
    parser.add_argument('--expect-stall',action='store_true')
    parser.add_argument('--first',choices=['timeout','failure','unindexed','indexed'],default='timeout')
    parser.add_argument('--nested',action='store_true')
    parser.add_argument('--cancel',action='store_true')
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='graff-probe-deadline-') as tmp:
        work=Path(tmp)
        (work/'bin').mkdir()
        probe=work/'bin/codedb'
        (work/'first-mode').write_text(args.first)
        probe.write_text(f'#!{sys.executable}\n'+'''import json, os, pathlib, subprocess, sys, time
root=pathlib.Path(__file__).resolve().parent.parent
if len(sys.argv)>1 and sys.argv[1]=='outline':
    counter=root/'probes.json'
    calls=json.loads(counter.read_text()) if counter.exists() else []
    calls.append(os.getpid())
    counter.write_text(json.dumps(calls))
    if len(calls)==1:
        mode=(root/'first-mode').read_text()
        if mode=='timeout':
            child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
            (root/'child-pid').write_text(str(child.pid))
            time.sleep(60)
        if mode=='failure':sys.exit(1)
        if mode=='unindexed':print('not indexed: fixture.zig');sys.exit()
    print('fixture symbol indexed')
else: print('fixture codedb')
''')
        probe.chmod(0o755)
        (work/'fixture.zig').write_text('pub const fixture_marker = 42;\n')
        env={k:v for k,v in os.environ.items() if not k.endswith('_API_KEY')}
        env.pop('GRAFF_NO_CODEDB_GUARD',None)
        env.update(HOME=tmp,PATH=str(work/'bin')+os.pathsep+env['PATH'],LMSTUDIO_API_KEY='local',
                   GRAFF_FLEET='off',GRAFF_NO_TELEMETRY='1',GRAFF_NO_SMOLIFY='1')
        call={'tool':'bash','arguments':{'command':'cat fixture.zig'}}
        replies=[call,call,call,{'text':'probe fixture completed'}]
        if args.nested:
            replies.insert(0,{'tool':'subagent','arguments':{'description':'probe fixture','prompt':'Run the local guard fixture in the shared directory.','isolation':'shared_cwd'}})
            replies.append({'text':'parent resumed after probe'})
        model=ScriptedModel(replies)
        model.start(1234)
        stdout=stderr=''
        stalled=False
        started=time.monotonic()
        try:
            try:
                if args.cancel:
                    assert not args.nested and args.first=='timeout' and not args.expect_stall
                    stdout,stderr=cancelled_run(args.binary,work,env)
                else:
                    result=run([str(args.binary.resolve()),'--json','--old','--yolo','--model','lmstudio'],
                        cwd=work,env=env,text=True,capture_output=True,timeout=9,
                        input=json.dumps({'type':'user','text':'Exercise the local source-read guard fixture.'})+'\n')
                    stdout,stderr=result.stdout,result.stderr
                    assert result.returncode==0,stderr[-1000:]
            except subprocess.TimeoutExpired as exc:
                stalled=True
                stdout=exc.stdout or ''
                stderr=exc.stderr or ''
                if isinstance(stdout,bytes):stdout=stdout.decode(errors='replace')
                if isinstance(stderr,bytes):stderr=stderr.decode(errors='replace')
            elapsed=time.monotonic()-started
            probes=json.loads((work/'probes.json').read_text())
            assert stalled==args.expect_stall, {'stalled':stalled,'elapsed':elapsed}
            if not args.expect_stall:
                assert len(probes)==(2 if args.first in ('timeout','failure') else 1), 'Incomplete probe must be retried; completed probe must be cached'
                assert len(model.requests)==(6 if args.nested else 4)
                results=[json.loads(l) for l in stdout.splitlines() if l.startswith('{')]
                results=[e for e in results if e.get('type')=='tool_result' and e.get('name')=='bash']
                if args.nested:
                    results=[{'text':m['content'],'is_error':'codedb-indexed' in m['content']} for m in model.requests[4]['messages'] if m.get('role')=='tool']
                    assert 'parent resumed after probe' in stdout
                if args.cancel:
                    results=[e for e in results if 'codedb-indexed' in e['text']]
                assert len(results)==(2 if args.cancel else 3),results
                for index,event in enumerate(results):
                    allowed=not args.cancel and (args.first=='unindexed' or (index==0 and args.first!='indexed'))
                    assert bool(event.get('is_error'))!=allowed,event
                    assert ('fixture_marker' if allowed else 'codedb-indexed') in event['text'],event
                pids=[probes[0]]
                if (work/'child-pid').exists():pids.append(int((work/'child-pid').read_text()))
                for pid in pids:
                    try: os.kill(pid,0)
                    except ProcessLookupError: pass
                    else: raise AssertionError('Completed probe or descendant survived its owned deadline')
            summary={'first':args.first,'nested':args.nested,'cancelled':args.cancel,'expected_stall':args.expect_stall,'stalled':stalled,'elapsed_seconds':elapsed,'outline_probes':len(probes)}
            (args.output/'result.json').write_text(json.dumps(summary,indent=2))
            print(json.dumps(summary))
        finally:
            model.stop()
            (args.output/'stdout.jsonl').write_text(stdout)
            (args.output/'stderr.log').write_text(stderr)
            (args.output/'requests.json').write_text(json.dumps(model.requests,indent=2))
            for folder in ('traces','trajectories'):
                source=work/'.graff'/folder
                if source.exists():shutil.copytree(source,args.output/folder,dirs_exist_ok=True)


if __name__=='__main__':main()
