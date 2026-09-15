#!/usr/bin/env python3
"""Exercise durable ownership through real ACP turns and local Git writes."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from github_fixture import prepare
from mock_model import ScriptedModel


def tool(name, **arguments):
    return {'tool': name, 'arguments': arguments}


class Client:
    def __init__(self, binary, work, env):
        self.proc = subprocess.Popen([binary, 'acp', '--model', 'lmstudio', '--old', '--yolo'],
            cwd=work, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        self.events = []
        self.queue = queue.Queue()
        self.serial = 0
        def read():
            for line in self.proc.stdout:
                try: self.queue.put(json.loads(line))
                except ValueError: pass
            self.queue.put(None)
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()
        self.call('initialize', {'protocolVersion': 1})
        self.sid = self.call('session/new', {})['result']['sessionId']

    def call(self, method, params):
        self.serial += 1
        self.proc.stdin.write(json.dumps(dict(jsonrpc='2.0', id=self.serial, method=method, params=params))+'\n')
        self.proc.stdin.flush()
        deadline = time.monotonic()+45
        while True:
            event = self.queue.get(timeout=max(.01, deadline-time.monotonic()))
            assert event is not None, 'ACP worker exited'
            self.events.append(event)
            if event.get('id') == self.serial:
                assert 'error' not in event, event
                return event

    def prompt(self, text):
        return self.call('session/prompt', {'sessionId': self.sid, 'prompt':[{'type':'text','text':text}]})

    def close(self):
        try: os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        self.proc.wait(timeout=3)
        self.thread.join(timeout=2)
        self.proc.stdin.close()
        self.proc.stdout.close()


class Model(ScriptedModel):
    def __init__(self):
        super().__init__([])
        self.owner_steps = []
        self.caller_steps = []

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            steps = self.owner_steps if 'fixture-lifecycle-owner' in json.dumps(body) else self.caller_steps
            return steps.pop(0) if steps else {'text':'Fixture turn finished.'}


def run(binary, recovery, evidence):
    model = Model()
    with tempfile.TemporaryDirectory(prefix='graff-claim-life-') as temp:
        work = Path(temp)
        env = {k:v for k,v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=temp, LMSTUDIO_API_KEY='local', GRAFF_NO_TELEMETRY='1',
            GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        prepare(work, env, {'checks':'SUCCESS', 'runs':'success', 'new_runs':'success', 'head_branch':'fixture'})
        subprocess.run(['git','init','--bare','-q',str(work/'remote.git')], check=True, timeout=10)
        subprocess.run(['git','remote','add','origin',str(work/'remote.git')], cwd=work, check=True, timeout=10)
        subprocess.run(['git','config','user.name','Fixture'], cwd=work, check=True, timeout=10)
        subprocess.run(['git','config','user.email','fixture@example.invalid'], cwd=work, check=True, timeout=10)
        (work/'probe.txt').write_text('owned fixture\n')
        initial = subprocess.check_output(['git','rev-parse','HEAD'], cwd=work, text=True).strip()
        commands = ['git add probe.txt', 'git commit -m fixture', 'git push origin HEAD',
                    'gh pr create --title fixture --body-file notes.md', 'gh pr edit 1 --title fixture']
        claim = lambda action: tool('peer_message', action=action, kind='publication', key='fixture', repo='fixture/primary')
        owner = caller = None
        model.start(1234)
        try:
            owner = Client(binary, work, env)
            caller = Client(binary, work, env)
            model.owner_steps = [claim('claim')]
            owner.prompt('fixture-lifecycle-owner: acquire and hold publication ownership.')
            def blocked_round(label):
                first = len(model.requests)
                unrelated = f'unrelated-{first}.txt'
                write = tool('write_file',path=unrelated,content='fixture')
                prefix = [write, write, tool('bash',command='gh pr list --json number')]
                model.caller_steps = prefix+[tool('bash',command=cmd) for cmd in commands+commands[:1]]
                caller.prompt(label)
                observed = model.requests[first:]
                # Each successive request contains the prior actual tool result.
                for request in observed[4:]:
                    assert 'artifact claim held' in request['messages'][-1]['content'], request['messages'][-1]
                assert '[]' in observed[3]['messages'][-1]['content']
                assert (work/unrelated).read_text() == 'fixture'
                assert len(observed) == len(commands)+5, len(observed)
                assert subprocess.check_output(['git','diff','--cached','--name-only'],cwd=work,text=True) == ''
                assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=work,text=True).strip() == initial
                assert not (work/'mutations.jsonl').exists()
            blocked_round('Attempt the claimed writes, then retry staging.')
            assert any('Re-issue the identical call to proceed' in r['messages'][-1].get('content','') for r in model.requests if r['messages'][-1]['role']=='tool'), 'shared-tree checkpoint was not exercised'
            caller.prompt('/save claim-lifecycle')
            caller.prompt('/resume claim-lifecycle')
            blocked_round('Repeat the claimed writes after resuming the saved conversation.')
            before_compact = len(model.requests)
            ledger_before = (work/'.graff/artifact-claims.json').read_text()
            model.caller_steps = [{'text':'COMPACTED_LIFECYCLE_FIXTURE: publication ownership remains with the live peer.'}]
            caller.prompt('/compact')
            assert len(model.requests) > before_compact, 'compaction did not request a summary'
            assert (work/'.graff/artifact-claims.json').read_text() == ledger_before
            compacted_turn = len(model.requests)
            blocked_round('Repeat the claimed writes after compacting the conversation.')
            assert 'COMPACTED_LIFECYCLE_FIXTURE' in json.dumps(model.requests[compacted_turn]), 'summary was not installed'
            assert owner.proc.poll() is None
            if recovery == 'release':
                model.owner_steps = [claim('release')]
                owner.prompt('fixture-lifecycle-owner: explicitly release publication ownership.')
            else:
                owner.close()
                owner = None
            recovery_commands = commands
            model.caller_steps = [claim('claim')]+[tool('bash',command=cmd) for cmd in recovery_commands]
            first = len(model.requests)
            caller.prompt('Acquire ownership after recovery, then perform the writes.')
            observed = model.requests[first:]
            assert len(observed)==len(recovery_commands)+2, len(observed)
            head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=work,text=True).strip()
            remote = subprocess.check_output(['git','--git-dir',str(work/'remote.git'),'rev-parse','refs/heads/fixture'],text=True).strip()
            assert head != initial and remote == head, (head, remote)
            mutations = (work/'mutations.jsonl').read_text().splitlines()
            assert len(mutations)==2, mutations
            print(f'PASS {recovery}: stage/commit/push/PR writes blocked across checkpoint, polling, resume and compaction; explicit recovery permits writes',flush=True)
        finally:
            if evidence:
                dest=evidence/recovery
                dest.mkdir(parents=True,exist_ok=True)
                (dest/'requests.json').write_text(json.dumps(model.requests,indent=2))
                for label,client in [('owner',owner),('caller',caller)]:
                    if client: (dest/f'{label}-acp.json').write_text(json.dumps(client.events,indent=2))
                for name in ['mutations.jsonl','gh-argv.jsonl','.graff/artifact-claims.json']:
                    source=work/name
                    if source.exists(): (dest/source.name).write_text(source.read_text())
            if owner: owner.close()
            if caller: caller.close()
            model.stop()


def independent_issue(binary, evidence):
    model = Model()
    with tempfile.TemporaryDirectory(prefix='graff-claim-issue-') as temp:
        work = Path(temp)
        env = {k:v for k,v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=temp, LMSTUDIO_API_KEY='local', GRAFF_NO_TELEMETRY='1',
            GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        prepare(work,env,{'checks':'SUCCESS'})
        owner = caller = None
        model.start(1234)
        try:
            owner = Client(binary,work,env)
            caller = Client(binary,work,env)
            model.owner_steps = [tool('peer_message',action='claim',kind='issue',key='1',repo='fixture/primary')]
            owner.prompt('fixture-lifecycle-owner: hold issue one.')
            model.caller_steps = [tool('bash',command='gh issue edit 1 --title fixture'),
                                  tool('bash',command='gh issue edit 2 --title fixture')]
            start = len(model.requests)
            caller.prompt('Try the claimed issue and then the unrelated issue.')
            requests = model.requests[start:]
            assert len(requests)==3
            assert 'artifact claim held' in requests[1]['messages'][-1]['content']
            mutations = [json.loads(line) for line in (work/'mutations.jsonl').read_text().splitlines()]
            assert mutations == [['issue','edit','2','--title','fixture']],mutations
            assert owner.proc.poll() is None
            print('PASS issue isolation: owned issue blocks while unrelated issue remains writable',flush=True)
        finally:
            if evidence:
                dest=evidence/'issue-isolation'
                dest.mkdir(parents=True,exist_ok=True)
                (dest/'requests.json').write_text(json.dumps(model.requests,indent=2))
                if caller: (dest/'caller-acp.json').write_text(json.dumps(caller.events,indent=2))
                if (work/'mutations.jsonl').exists(): (dest/'mutations.jsonl').write_text((work/'mutations.jsonl').read_text())
            if owner: owner.close()
            if caller: caller.close()
            model.stop()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff',default='zig-out/bin/graff')
    parser.add_argument('--evidence',type=Path)
    args=parser.parse_args()
    for recovery in ['release','stale-owner']:
        run(str(Path(args.graff).resolve()),recovery,args.evidence)
    independent_issue(str(Path(args.graff).resolve()),args.evidence)


if __name__ == '__main__': main()
