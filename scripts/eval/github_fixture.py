"""Local-only GitHub CLI fixture for production dispatch regressions."""
import json
import os
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
    selected=args[-1] if '--' in args else state.get('repo','fixture/primary')
    url=selected if selected.startswith('https://') else 'https://github.com/'+selected
    print(json.dumps({'url':url}))
elif args[:2]==['run','list']:
    if state.get('unavailable'):sys.exit(1)
    sha=args[args.index('--commit')+1]
    status=state.get('runs','success') if sha==state['initial_head'] else state.get('new_runs','failure')
    if status=='malformed': print('invalid');sys.exit()
    if status=='none': print('[]');sys.exit()
    print(json.dumps([{'status':'queued' if status=='pending' else 'completed','conclusion':None if status=='pending' else status}]))
elif args[:1]==['api']:
    print(state.get('remote_head', head))
elif args[:2]==['pr','list']:
    print('[]')
elif args[:2]==['pr','view']:
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
    print(json.dumps({'headRefOid':remote,'isDraft':state.get('draft',False),'body':'## Verification\nLocal tests passed.','statusCheckRollup':checks,'headRefName':state.get('head_branch','fixture'),'number':1,'url':url+'/pull/1','headRepository':{'nameWithOwner':state.get('head_repo',url.split('://',1)[-1].split('/',1)[1])}}))
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
                    "commit", "-q", "--allow-empty", "-m", "fixture"], cwd=work, check=True, timeout=10)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=work, text=True, timeout=10).strip()
    fixture = dict(initial_head=head, **state)
    if fixture.get("remote_head") == "initial":
        fixture["remote_head"] = head
    (work / "gh-state.json").write_text(json.dumps(fixture))
    (work / "notes.md").write_text("## Verification\nLocal regression passed.\n")
    env["PATH"] = str(bindir) + os.pathsep + env["PATH"]
