"""Real harness claim review with local model and GitHub fixtures."""
import argparse, json, os, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts/eval'))
from github_fixture import prepare
from mock_model import ScriptedModel
from process_guard import run

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case', choices=['unsupported','unresolved','supported','invalid'], default='unsupported')
parser.add_argument('--plain', action='store_true')
parser.add_argument('--oneshot', action='store_true')
parser.add_argument('--budget-exhausted', action='store_true')
parser.add_argument('--ready', action='store_true')
parser.add_argument('--repo', action='store_true')
parser.add_argument('--url', action='store_true')
parser.add_argument('--changed-body', action='store_true')
parser.add_argument('--binary', type=Path, default=ROOT/'zig-out/bin/graff')
parser.add_argument('--output', type=Path, default=ROOT/'zig-out/pr-claim-review')
args=parser.parse_args()
verdict,plain=args.case,args.plain
output=args.output/(verdict+('-plain' if plain else '')+('-oneshot' if args.oneshot else '')+('-budget' if args.budget_exhausted else ''))
if args.ready or args.repo:
    output=output.with_name(output.name+('-ready' if args.ready else '')+('-repo' if args.repo else ''))
if args.url:
    output=output.with_name(output.name+'-url')
if args.changed_body:
    assert verdict=='supported' and not (args.ready or args.url or args.budget_exhausted)
    output=output.with_name(output.name+'-changed-body')
output.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='graff-coverage-') as tmp:
    work = Path(tmp)
    env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
    env.update(HOME=tmp, LMSTUDIO_API_KEY='local', GRAFF_FLEET='off',
               GRAFF_NO_TELEMETRY='1', GRAFF_NO_SMOLIFY='1',
               GRAFF_NO_CODEDB_GUARD='1', PYTHONDONTWRITEBYTECODE='1')
    prepare(work, env, {'checks': 'SUCCESS'})
    base=json.loads((work/'gh-state.json').read_text())['initial_head']
    (work/'editor.py').write_text('''def remove_atomic(text, start):
    return text[:start]

def delete_word(text, start, end):
    # Deliberate fixture defect: two trailing separators take generic parsing.
    if len(text[end:]) <= 1:
        return remove_atomic(text, start)
    return text.rstrip().rsplit(' ', 1)[0] + ' '
''')
    (work/'test_helper.py').write_text('''import unittest
from editor import remove_atomic
class HelperTests(unittest.TestCase):
    def test_atomic_helper(self):
        self.assertEqual(remove_atomic('say /tmp/file with spaces.txt ', 4), 'say ')
''')
    (work/'dispatch_probe.py').write_text('''from editor import delete_word
token = '/tmp/file with spaces.txt'
for separator in ['', ' ', '  ', '\\t ']:
    text = 'say ' + token + separator
    actual = delete_word(text, 4, 4 + len(token))
    assert actual == 'say ', (repr(separator), actual)
''')
    (work/'notes.md').write_text('''Atomic deletion is preserved for pasted tokens.
The helper regression exercises dispatch and multiple separators on the deletion path.

## Verification
Local: `python3 -m unittest test_helper -v` passed.
Remote: passed.
''')
    if verdict=='supported':
        (work/'editor.py').write_text("def remove_atomic(text, start):\n    return text[:start]\n\ndef delete_word(text, start, end):\n    if not text[end:].strip():\n        return remove_atomic(text, start)\n    return text.rstrip().rsplit(' ', 1)[0] + ' '\n")
        (work/'test_helper.py').write_text("import unittest\nfrom editor import delete_word\nclass DispatchTests(unittest.TestCase):\n    def test_delete_dispatch(self):\n        token='/tmp/file with spaces.txt'\n        for separator in ['', ' ', '  ', '\\t ']:\n            with self.subTest(separator=separator):\n                self.assertEqual(delete_word('say '+token+separator,4,4+len(token)), 'say ')\n")
    if plain:
        (work/'notes.md').write_text('Deletion handles trailing separators.\nLocal: `python3 -m unittest test_helper -v` passed.\nRemote: passed.\n')
    subprocess.run(['git','add','editor.py','test_helper.py','dispatch_probe.py','notes.md'],cwd=work,check=True)
    subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                    'commit','-qm','fixture behavior and regression'],cwd=work,check=True)
    state=json.loads((work/'gh-state.json').read_text())
    state['base_sha']=base
    state['body']=(work/'notes.md').read_text()
    state['initial_head']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=work,text=True).strip()
    (work/'gh-state.json').write_text(json.dumps(state))
    publication='gh pr ready 1' if args.ready else 'gh pr create --base fixture-base --title fixture --body-file notes.md'
    if args.url:
        publication='gh pr ready https://github.com/fixture/alternate/pull/1'
    if args.repo:
        publication += ' --repo fixture/alternate'
    replies=[
        {'tool':'bash','arguments':{'command':'python3 -m unittest test_helper -v'}},
        {'tool':'bash','arguments':{'command':publication}},
        {'text': 'invalid review' if verdict=='invalid' else json.dumps({'verdict':verdict,'reason':'Controlled review response for the committed fixture; not a semantic proof.'})},
        {'text':'Fixture ended.'},
    ]
    if args.budget_exhausted:
        del replies[2]  # The review cannot consume the root's final reserved call.
    if args.changed_body:
        replies[3:3]=[
            {'tool':'bash','arguments':{'command':"printf 'Deletion handles every possible separator.\\nLocal: `python3 -m unittest test_helper -v` passed.\\nRemote: passed.\\n' > notes.md"}},
            {'tool':'bash','arguments':{'command':publication}},
            {'text':json.dumps({'verdict':'unsupported','reason':'Changed claim exceeds the tested cases.'})},
        ]
    model=ScriptedModel(replies)
    model.start(1234)
    try:
        prompt='Run the committed helper regression and exercise publication against the local fake GitHub service.'
        command=[str(args.binary.resolve()),'--old','--yolo','--model','lmstudio']
        if args.budget_exhausted:
            command += ['--max-model-calls','3']
        command += ['-p',prompt] if args.oneshot else ['--json']
        result=run(command,
                   cwd=work,env=env,text=True,capture_output=True,timeout=90,
                   input=None if args.oneshot else json.dumps({'type':'user','text':prompt})+'\n')
        probe=subprocess.run([sys.executable,'dispatch_probe.py'],cwd=work,env=env,text=True,capture_output=True,timeout=10)
        mutations=(work/'mutations.jsonl').read_text() if (work/'mutations.jsonl').exists() else ''
        events=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        (output/'events.json').write_text(json.dumps(events,indent=2))
        (output/'requests.json').write_text(json.dumps(model.requests,indent=2))
        (output/'mutations.jsonl').write_text(mutations)
        (output/'dispatch-probe.log').write_text(probe.stdout+probe.stderr)
        (output/'harness-stderr.log').write_text(result.stderr)
        for name in ['editor.py','test_helper.py','dispatch_probe.py','notes.md']:
            (output/name).write_text((work/name).read_text())
        summary={'harness_exit':result.returncode,'publication_executed':bool(mutations),
                 'independent_dispatch_exit':probe.returncode,'model_requests':len(model.requests)}
        (output/'result.json').write_text(json.dumps(summary,indent=2))
        print(json.dumps(summary))
        assert result.returncode==0
        if args.oneshot:
            assert 'Controlled review response' not in result.stdout, 'Internal review must not stream into the user answer'
            assert 'Fixture ended.' in result.stdout
        assert bool(mutations)==(verdict=='supported' and not args.budget_exhausted), 'The publication boundary must enforce the review verdict and budget'
        assert len(model.requests)==(7 if args.changed_body else 3 if args.budget_exhausted else 4), 'Review shares the budget and rechecks changed inputs'
        if args.changed_body:
            assert len(mutations.splitlines())==1, 'Changed body must not reuse the previous approval'
            assert 'every possible separator' in json.dumps(model.requests[5])
        if not args.budget_exhausted:
            review_request=json.dumps(model.requests[2])
            assert 'changed committed files' in review_request and 'delete_word' in review_request and 'test_helper.py' in review_request
            observed=json.loads(model.requests[2]['messages'][-1]['content'])['observed_local_checks']
            assert len(observed)==1 and observed[0]['command']=='python3 -m unittest test_helper -v'
            assert observed[0]['completed'] and not observed[0]['failed'] and 'Ran 1 test' in observed[0]['output']
            if args.repo or args.url:
                assert 'https://github.com/fixture/alternate' in review_request
        else:
            assert 'Fixture ended.' in result.stdout, 'Root must retain its final answer call'
        assert (probe.returncode==0)==(verdict=='supported'), 'Independent dispatch probe must match broken/repaired fixture'
    finally:
        model.stop()
