"""Local-only GitHub CLI fixture for production dispatch regressions."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

GH = r'''
import json, pathlib, subprocess, sys, time, urllib.parse
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
elif args[:1]==['issue'] and len(args)>1 and args[1] in ('list','view','comment','reopen','create'):
    # Stateful local issue tracker: unsupported operations fail closed, never
    # delegate to a real gh. Both successful and denied mutations are recorded.
    def option(*names, default=None):
        for name in names:
            if name in args:return args[args.index(name)+1]
        return default
    def save():
        (root/'gh-state.json').write_text(json.dumps(state))
    def emit(value):
        fields=option('--json')
        if fields:
            selected=fields.split(',')
            value=[{k:v.get(k) for k in selected} for v in value] if isinstance(value,list) else {k:value.get(k) for k in selected}
        query=option('--jq')
        if query:
            if query not in ('.state','.number','.url','.stateReason'):sys.exit(87)
            print(value[query[1:]])
        else:print(json.dumps(value))
    selected=option('--repo','-R',default=state.get('repo','fixture/primary'))
    if selected!=state.get('repo','fixture/primary'):sys.exit(86)
    issues=state.setdefault('issues',{})
    action=args[1]
    if action=='list':
        if state.get('issue_list_denied'):
            print('GraphQL: Resource not accessible by integration (search)',file=sys.stderr)
            sys.exit(1)
        wanted=option('--state','-s',default='open').upper()
        search=option('--search','-S',default='').lower()
        found=[v for v in issues.values() if (wanted=='ALL' or v['state']==wanted) and (not search or search in (v['title']+' '+v.get('body','')).lower())]
        emit(found[:int(option('--limit','-L',default='30'))])
    else:
        if action=='create':
            number=str(max([int(n) for n in issues]+[0])+1)
        else:
            selector=args[2]
            if '://' in selector:
                url=urllib.parse.urlsplit(selector)
                parts=url.path.strip('/').split('/')
                if url.scheme!='https' or url.netloc!='github.com' or len(parts)!=4 or parts[2]!='issues' or '/'.join(parts[:2])!=selected:sys.exit(86)
                number=parts[3]
            else:number=selector
            if not number.isdecimal() or number not in issues:sys.exit(85)
        if action=='view':
            if issues[number].get('deny_view_after_mutation') and (root/'mutations.jsonl').exists():
                print('GraphQL: Resource not accessible by integration (issue)',file=sys.stderr)
                sys.exit(1)
            emit(issues[number])
        else:
            with (root/'mutations.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
            if action=='reopen':
                if issues[number].get('deny_reopen'):
                    print('GraphQL: Resource not accessible by integration (reopenIssue)',file=sys.stderr)
                    sys.exit(1)
                issues[number].update(state='OPEN',stateReason='',closedAt=None)
            else:
                if action=='comment' and issues[number].get('deny_comment'):
                    print('GraphQL: Resource not accessible by integration (addComment)',file=sys.stderr)
                    sys.exit(1)
                body=option('--body','-b')
                if body is None:
                    filename=option('--body-file','-F')
                    if not filename:sys.exit(84)
                    body=sys.stdin.read() if filename=='-' else pathlib.Path(filename).read_text()
                if action=='create':
                    issues[number]=dict(number=int(number),title=option('--title','-t',default='fixture'),body=body,state='OPEN',stateReason='',comments=[],url='https://github.com/'+selected+'/issues/'+number)
                else:issues[number].setdefault('comments',[]).append({'body':body})
            save()
            print(issues[number].get('url','https://github.com/'+selected+'/issues/'+number))
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
