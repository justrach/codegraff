#!/usr/bin/env python3
"""Two live harness processes verify repository and PR artifact ownership.
All GitHub calls use a local fixture; no remote mutation is possible.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from github_fixture import prepare, prepare_review
from mock_model import ScriptedModel
from claim_ledger import path as claim_ledger_path


def tool(name, **arguments):
    return {'tool': name, 'arguments': arguments}


CASES = {
    'release-during-lookup': dict(owner='fixture/primary', caller='fixture/primary', held='feature', allow=True, wait_release=True),
    'different-repositories': dict(owner='fixture/primary', caller='fixture/other', held='feature', allow=True),
    'same-artifact': dict(owner='fixture/primary', caller='fixture/primary', held='feature', allow=False),
    'different-branches': dict(owner='fixture/primary', caller='fixture/primary', held='unrelated', allow=True),
    'different-hosts': dict(owner='https://git.example/fixture/primary', caller='fixture/primary', held='feature', allow=True),
    'pr-url': dict(owner='fixture/primary', caller='fixture/other', held='feature', allow=True, url=True),
    'flags-first': dict(owner='fixture/primary', caller='fixture/primary', held='unrelated', allow=True, flags_first=True),
    'unknown-pr': dict(owner='fixture/primary', caller='fixture/other', held='feature', allow=False, pr_unavailable=True),
    'legacy-unknown': dict(owner='fixture/primary', caller='fixture/other', held='feature', allow=False, legacy=True),
    'legacy-rebound': dict(owner='fixture/primary', caller='fixture/other', held='feature', allow=True, legacy=True, rebind=True),
    'fork-owner': dict(owner='fork/primary', caller='fixture/primary', held='feature', allow=False, head_repo='fork/primary'),
    'unrelated-fork': dict(owner='unrelated/primary', caller='fixture/primary', held='feature', allow=True, head_repo='fork/primary'),
    'unrelated-base-branch': dict(owner='fixture/primary', caller='fixture/primary', held='feature', allow=True, head_repo='fork/primary', owner_kind='branch'),
}


class Model(ScriptedModel):
    def __init__(self, case):
        super().__init__([])
        self.case = case
        self.counts = {}
        self.owner_ready = threading.Event()
        self.work = None

    def next_reply(self, body):
        if 'committed_inputs' in json.dumps(body):
            with self._lock: self.requests.append(body)
            return {'text':json.dumps({'verdict':'supported','reason':'Controlled review for the committed fixture.'})}
        actor = 'owner' if 'fixture-owner-only' in json.dumps(body) else 'caller'
        with self._lock:
            self.requests.append(body)
            step = self.counts.get(actor, 0)
            self.counts[actor] = step + 1
        c = self.case
        if actor == 'owner':
            if step == 0:
                return tool('peer_message', action='claim', kind=c.get('owner_kind','publication'), key=c['held'], repo=c['owner'])
            if c.get('wait_release') and step == 2:
                return tool('peer_message', action='release', kind='publication', key=c['held'], repo=c['owner'])
            if c.get('wait_release') and step == 3:
                assert 'claim released' in json.dumps(body), body
                (self.work/'release-done').touch()
            if c.get('legacy') and step == 1:
                command = "python3 - <<'PYCLAIM'\nimport json, subprocess\nfrom pathlib import Path\ncommon=subprocess.check_output(['git','rev-parse','--git-common-dir'], text=True).strip()\np=Path(common)/'artifact-claims.json'\nrows=json.loads(p.read_text())\nfor row in rows: row.pop('repo',None)\np.write_text(json.dumps(rows))\nPYCLAIM"
                return tool('bash', command=command)
            if c.get('rebind') and step == 2:
                return tool('peer_message', action='claim', kind=c.get('owner_kind','publication'), key=c['held'], repo=c['owner'])
            self.owner_ready.set()
            return {'text': 'Claim remains held.'}
        selector = f'https://github.com/{c["caller"]}/pull/1' if c.get('url') else '1'
        option = '' if c.get('url') else f' --repo {c["caller"]}'
        edit = f'gh pr edit {selector}{option} --title fixture'
        ready = f'gh pr ready {selector}{option}'
        if c.get('flags_first'):
            edit = f'gh --repo {c["caller"]} pr edit --title fixture 1'
            ready = f'gh --repo {c["caller"]} pr ready 1'
        steps = [
            tool('peer_message', action='claim', kind='branch', key='feature', repo=c.get('head_repo',c['caller'])),
            tool('peer_message', action='claim', kind='pull_request', key='1', repo=c['caller']),
            tool('bash', command=edit), tool('bash', command=ready),
            {'text': 'Ownership result observed.'},
        ]
        return steps[min(step, len(steps)-1)]


def run_case(binary, name, case, evidence):
    model = Model(case)
    with tempfile.TemporaryDirectory(prefix='graff-claim-repo-') as temp:
        work = Path(temp)
        model.work = work
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=temp, LMSTUDIO_API_KEY='local', GRAFF_NO_TELEMETRY='1',
                   GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        state = dict(checks='SUCCESS', head_branch='feature', pr_unavailable=case.get('pr_unavailable', False))
        state['wait_release'] = case.get('wait_release', False)
        if 'head_repo' in case: state['head_repo'] = case['head_repo']
        prepare(work, env, state)
        prepare_review(work, ['notes.md'])
        model.start(1234)
        owner = None
        release_thread = None
        stop_release = threading.Event()
        try:
            argv = [binary, '--json', '--yolo', '--old', '--model', 'lmstudio']
            owner = subprocess.Popen(argv, cwd=work, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     text=True, start_new_session=True)
            owner.stdin.write(json.dumps({'type': 'user', 'text': 'fixture-owner-only: acquire publication ownership and hold it.'})+'\n')
            owner.stdin.flush()
            assert model.owner_ready.wait(30), 'owner did not claim'
            assert owner.poll() is None, 'owner exited'
            if case.get('wait_release'):
                def release_when_lookup_starts():
                    while not stop_release.wait(.02):
                        if (work/'lookup-start').exists():
                            owner.stdin.write(json.dumps({'type':'user','text':'fixture-owner-only: release the claim now.'})+'\n')
                            owner.stdin.flush()
                            return
                release_thread = threading.Thread(target=release_when_lookup_starts)
                release_thread.start()
            done = subprocess.run(argv, cwd=work, env=env, input=json.dumps({'type': 'user', 'text': 'Claim the target branch and PR, then edit and mark it ready.'})+'\n', capture_output=True, text=True, timeout=45)
            events = [json.loads(line) for line in done.stdout.splitlines() if line.startswith('{')]
            claims = json.loads(claim_ledger_path(work).read_text())
            mutations = (work/'mutations.jsonl').read_text().splitlines() if (work/'mutations.jsonl').exists() else []
            if evidence:
                dest = evidence/name
                dest.mkdir(parents=True, exist_ok=True)
                (dest/'events.jsonl').write_text(done.stdout)
                (dest/'stderr.log').write_text(done.stderr)
                (dest/'requests.json').write_text(json.dumps(model.requests, indent=2))
                (dest/'claims.json').write_text(json.dumps(claims, indent=2))
                (dest/'mutations.json').write_text(json.dumps(mutations, indent=2))
            assert done.returncode == 0, done.stderr[-1500:]
            assert owner.poll() is None, 'owner must remain live through both mutations'
            owner_held = any(c['kind']==case.get('owner_kind','publication') and c['pid']==owner.pid for c in claims)
            assert owner_held != case.get('wait_release', False), claims
            assert any(c['kind']=='pull_request' and c['key']=='1' and c['pid']!=owner.pid for c in claims), claims
            results = [e for e in events if e.get('type')=='tool_result' and e.get('name')=='bash']
            assert len(results)==2, results
            assert all(e.get('is_error') != case['allow'] for e in results), results
            assert len(mutations)==(2 if case['allow'] else 0), mutations
            if not case['allow']:
                assert all('artifact claim held' in e['text'] for e in results), results
            print(f'PASS {name}: both mutations {"allowed" if case["allow"] else "blocked"} with owner still live', flush=True)
        finally:
            stop_release.set()
            if release_thread: release_thread.join(timeout=2)
            if owner:
                try: os.killpg(owner.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                owner.wait(timeout=3)
                owner.stdin.close()
            model.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', default='zig-out/bin/graff')
    parser.add_argument('--only', choices=CASES)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    for name, case in CASES.items():
        if args.only and name != args.only:
            continue
        run_case(binary, name, case, args.evidence)


if __name__ == '__main__':
    main()
