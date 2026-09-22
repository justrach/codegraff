"""Local-only GitHub CLI fixture for production dispatch regressions."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

GH = r'''
import json, pathlib, subprocess, sys, time
root=pathlib.Path(__file__).resolve().parent.parent
state=json.loads((root/'gh-state.json').read_text())
args=sys.argv[1:]
with (root/'gh-argv.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
if len(args)>2 and args[0] in ('--repo','-R'): args=args[2:]+['--repo',args[1]]
head=subprocess.check_output(['GIT_EXE','rev-parse','HEAD'],cwd=root,text=True).strip()
if args[:2]==['repo','view']:
    if state.get('repo_unavailable'): sys.exit(1)
    selected=args[-1] if '--' in args else args[2] if len(args)>2 and not args[2].startswith('-') else state.get('repo','fixture/primary')
    url=selected if selected.startswith('https://') else 'https://github.com/'+selected
    print(url if '--jq' in args and args[args.index('--jq')+1]=='.url' else 'fixture-base' if '--jq' in args else json.dumps({'url':url}))
elif args[:2]==['run','list']:
    if state.get('unavailable'):sys.exit(1)
    sha=args[args.index('--commit')+1]
    status=state.get('runs','success') if sha==state['initial_head'] else state.get('new_runs','failure')
    if state.get('run_sequence'):
        sample=state.get('run_sample',0)
        status=state['run_sequence'][min(sample,len(state['run_sequence'])-1)]
        state['run_sample']=sample+1
        (root/'gh-state.json').write_text(json.dumps(state))
    if status=='malformed': print('invalid');sys.exit()
    if status=='none': print('[]');sys.exit()
    print(json.dumps([{'status':'queued' if status=='pending' else 'completed','conclusion':None if status=='pending' else status}]))
elif args[:1]==['api']:
    print(state.get('base_sha', state['initial_head']) if '/heads/fixture-base' in ' '.join(args) else state.get('remote_head', head))
elif args[:2]==['pr','list']:
    print('[]')
elif args[:2]==['pr','view']:
    if '--jq' in args and args[args.index('--jq')+1]=='.baseRefOid':
        print(state.get('base_sha',state['initial_head']));sys.exit()
    if state.get('wait_release') and '--json' in args and args[args.index('--json')+1].startswith('number,'):
        (root/'lookup-start').touch()
        deadline=time.monotonic()+12
        while not (root/'release-done').exists():
            if time.monotonic()>deadline: sys.exit(89)
            time.sleep(.02)
    if state.get('pr_unavailable'): sys.exit(1)
    selected=args[args.index('--repo')+1] if '--repo' in args else state.get('repo','fixture/primary')
    url=selected if selected.startswith('https://') else 'https://github.com/'+selected
    selector=args[2] if len(args)>2 and not args[2].startswith('-') else '1'
    if selector.startswith('https://') and '/pull/' in selector: url=selector.rsplit('/pull/',1)[0]
    remote=state.get('remote_head',head)
    status=state.get('checks','PENDING')
    checks=state.get('check_rollup', [] if status=='NONE' else [{'context':'fixture CI','state':status}])
    print(json.dumps({'headRefOid':remote,'isDraft':state.get('draft',False),'body':state.get('body','## Verification\nLocal: `python3 -m unittest` passed.\nRemote: passed.'),'statusCheckRollup':checks,'headRefName':state.get('head_branch','fixture'),'number':1,'url':url+'/pull/1','headRepository':{'nameWithOwner':state.get('head_repo',url.split('://',1)[-1].split('/',1)[1])}}))
    sys.exit(state.get('pr_exit',0))
elif args[:2] in (['pr','create'],['pr','ready'],['pr','edit'],['issue','edit']):
    with (root/'mutations.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
    if '--draft' in args:state['draft']=True
    if args[:2]==['pr','ready']:state['draft']=False
    (root/'gh-state.json').write_text(json.dumps(state))
    print('https://example.invalid/pull/1')
else: sys.exit(88)
'''


def prepare(work, env, state):
    bindir = work / "bin"
    bindir.mkdir(exist_ok=True)
    gh = bindir / "gh"
    gh.write_text(f"#!{sys.executable}\n" + GH.replace("GIT_EXE", shutil.which("git")))
    gh.chmod(0o755)
    subprocess.run(["git", "init", "-q", "-b", "fixture"], cwd=work, check=True, timeout=10)
    subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false",
                    "commit", "-q", "--allow-empty", "-m", "fixture"], cwd=work, check=True, timeout=10)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=work, text=True, timeout=10).strip()
    fixture = dict(initial_head=head, **state)
    if fixture.get("remote_head") == "initial":
        fixture["remote_head"] = head
    (work / "gh-state.json").write_text(json.dumps(fixture))
    (work / "notes.md").write_text("## Verification\nLocal: `python3 -m unittest` passed.\nRemote: passed.\n")
    env["PATH"] = str(bindir) + os.pathsep + env["PATH"]
    if fixture.get("review_files"):
        prepare_review(work, fixture["review_files"])


def claim_ledger(work):
    """Canonical claim file (Git common dir), then the legacy workspace copy."""
    work = Path(work)
    for args in (
        ["git", "-C", str(work), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        ["git", "-C", str(work), "rev-parse", "--git-common-dir"],
    ):
        try:
            raw = subprocess.check_output(args, text=True, timeout=10).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
        if not raw:
            continue
        common = Path(raw) if Path(raw).is_absolute() else (work / raw)
        path = common / "artifact-claims.json"
        if path.exists():
            return path
    return work / ".graff" / "artifact-claims.json"


def prepare_review(work, files):
    """Give readiness fixtures an actual committed diff and resolvable base."""
    state = json.loads((work / "gh-state.json").read_text())
    state["base_sha"] = state["initial_head"]
    subprocess.run(["git", "add", "--", *files], cwd=work, check=True, timeout=10)
    subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false",
                    "commit", "-qm", "fixture reviewed change"], cwd=work, check=True, timeout=10)
    state["initial_head"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=work, text=True, timeout=10).strip()
    state["new_runs"] = "success"
    (work / "gh-state.json").write_text(json.dumps(state))
