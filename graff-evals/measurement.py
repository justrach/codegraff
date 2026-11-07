"""Private reproducible eval receipts; missing prices remain unknown."""
import functools
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
FOOTER = re.compile(r'^\[usage\]\s+(?:known subtotal:\s*)?(\d+) api call\(s\)\s*·\s*(\d+) in \((\d+) cached(?:, (\d+) cache writes)?\)\s*\+\s*(\d+) out tokens(?:\s*·\s*\$([0-9]+(?:\.[0-9]+)?))?(.*)$')


def graff_usage(stderr):
    """Only the final cumulative harness footer is authoritative, never prose dollars."""
    matches = [FOOTER.fullmatch(ANSI.sub('', line).strip()) for line in stderr.splitlines()]
    found = [m for m in matches if m]
    if not found:
        return {}
    m = found[-1]
    result = dict(zip(('calls', 'in', 'cached', 'writes', 'out'),
                      (int(m.group(i) or 0) for i in range(1, 6))))
    if m.group(6) is not None:
        result['cost_usd'] = float(m.group(6))
        result['cost_kind'] = 'harness-reported'
    tail = m.group(7)
    for key, pattern in [('sub_calls', r'(\d+) subscription call'),
                         ('unpriced_calls', r'(\d+) call\(s\) (?:on unpriced models|with unknown cost)')]:
        if hit := re.search(pattern, tail):
            result[key] = int(hit.group(1))
    if result.get('unpriced_calls'):
        result['cost_usd'] = None
        result['cost_kind'] = 'incomplete-unpriced'
    elif result.get('sub_calls'):
        result['metered_cost_usd'] = result.get('cost_usd')
        result['cost_usd'] = None
        result['cost_kind'] = 'metered-only-subscription-excluded'
    missing = re.search(r'totals incomplete: (\d+) call\(s\) missing usage \(tokens and cost unknown\)', tail)
    failed = re.search(r'totals incomplete: (\d+) failed request attempt\(s\) without usage \(tokens and cost unknown\)', tail)
    if missing and int(missing.group(1)):
        result['missing_usage_calls'] = int(missing.group(1))
    if failed and int(failed.group(1)):
        result['unreported_failed_attempts'] = int(failed.group(1))
    # The prefix alone is sufficient evidence of incompleteness, even if a
    # newer runtime introduces an unfamiliar explanation in the tail.
    subtotal = re.match(r'^\[usage\]\s+known subtotal:', m.group(0)) is not None
    cost_only_subtotal = subtotal and result.get('unpriced_calls') and re.fullmatch(
        r'\s*(?:·\s*\d+ subscription call\(s\), flat-rate \(not in \$\)\s*)?'
        r'·\s*\d+ call\(s\) (?:on unpriced models|with unknown cost)\s*', tail)
    if cost_only_subtotal:
        result['usage_complete'] = True
        result['known_cost_usd'] = float(m.group(6)) if m.group(6) is not None else None
    elif subtotal or result.get('missing_usage_calls') or result.get('unreported_failed_attempts'):
        result['usage_complete'] = False
        for key in ('in', 'cached', 'writes', 'out'):
            result['known_' + key] = result[key]
            result[key] = None
        # The footer dollar amount is a subtotal, including when it is zero.
        result['known_cost_usd'] = float(m.group(6)) if m.group(6) is not None else None
        result['cost_usd'] = None
        result['cost_kind'] = ('incomplete-missing-usage' if result.get('missing_usage_calls') else
                               'incomplete-unreported-failed-attempts' if result.get('unreported_failed_attempts') else
                               'incomplete-known-subtotal')
    return result


@functools.lru_cache(maxsize=32)
def file_hash(path):
    try:
        digest = hashlib.sha256()
        with open(path, 'rb') as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def revision(repo):
    def git(*args):
        p = subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True, check=False)
        return p.stdout.strip() if p.returncode == 0 else None
    patch = subprocess.run(['git', '-C', repo, 'diff', 'HEAD', '--binary'], capture_output=True, check=False).stdout
    untracked = subprocess.run(['git', '-C', repo, 'ls-files', '--others', '--exclude-standard', '-z'], capture_output=True, check=False).stdout
    sources = {}
    for raw in untracked.split(b'\0'):
        if not raw:
            continue
        relative = os.fsdecode(raw)
        if Path(relative).suffix in ('.zig', '.py', '.sh', '.json', '.toml', '.md'):
            sources[relative] = file_hash(os.path.join(repo, relative))
    return {'source_receipt_scope': 'evaluation working tree; binary SHA is authoritative', 'untracked_source_sha256': sources, 'code_revision': git('rev-parse', 'HEAD'), 'code_dirty': bool(git('status', '--porcelain')),
            'tracked_patch_sha256': hashlib.sha256(patch).hexdigest()}


def receipt(command, harness, task):
    binary = shutil.which(command[0]) or command[0]
    return {**harness.get('_receipt', {}), 'binary_sha256': file_hash(os.path.realpath(binary)),
            'task_sha256': hashlib.sha256(json.dumps(task, sort_keys=True).encode()).hexdigest(),
            'requested_provider': harness.get('_provider'), 'arm': harness.get('_arm', 'baseline')}


def isolated_paths(parent):
    root = Path(parent) if parent else Path(__file__).resolve().parent / 'results' / ('run-' + uuid.uuid4().hex)
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    sandboxes = root / 'sandboxes'
    sandboxes.mkdir(mode=0o700)
    return str(root / 'results.jsonl'), str(sandboxes)


def private_logs(sandbox, stdout, stderr):
    for name, text in (('stdout', stdout), ('stderr', stderr)):
        fd = os.open(os.path.join(sandbox, f'.eval-{name}.txt'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as log:
            log.write(text)

# Each route inherits only its explicit API credential or Codex auth-directory path.
CREDENTIALS = {'codegraff': 'CODEGRAFF_API_KEY', 'openai': 'OPENAI_API_KEY',
               'anthropic': 'ANTHROPIC_API_KEY', 'xai': 'XAI_API_KEY', 'codex': 'CODEX_HOME'}


def provider_environment(provider, sandbox, source=None, model=None):
    source = os.environ if source is None else source
    credential = CREDENTIALS.get(provider)
    if not credential:
        raise ValueError('explicit provider requires a supported credential route')
    if not source.get(credential):
        raise ValueError(f'{credential} must be supplied in the environment')
    if provider == 'codex' and not (Path(source[credential]).expanduser() / 'auth.json').is_file():
        raise ValueError('CODEX_HOME must identify an existing auth.json directory')
    home = Path(sandbox) / '.eval-home'
    home.mkdir(mode=0o700)
    if model:
        if "\n" in model or "\r" in model:
            raise ValueError("model name must fit one saved-selection line")
        (home / '.simple-harness-model').write_text(f'{provider}\n{model}\n')
    env = {k: source[k] for k in ('PATH', 'LANG', 'LC_ALL', 'SDKROOT', 'DEVELOPER_DIR', 'SYSTEMROOT') if k in source}
    value = str(Path(source[credential]).expanduser().resolve()) if provider == 'codex' else source[credential]
    env.update({credential: value, 'HOME': str(home), 'USERPROFILE': str(home),
                'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                # The global MCP config points inside the isolated home and does not
                # exist: the user's servers stay out, and the task's .mcp.json still
                # merges. An existing empty override would switch MCP off (#549).
                'PWD': sandbox, 'GRAFF_MCP_CONFIG': str(home / '.codegraff' / 'mcp.json'), 'GRAFF_FLEET': 'off',
                'GRAFF_NO_TELEMETRY': '1', 'GRAFF_NO_SMOLIFY': '1', 'GRAFF_BEHAVIOR_UPLOAD': 'off', 'NO_COLOR': '1'})
    return env


def trace_routing(sandbox, provider, model):
    rows = []
    for path in (Path(sandbox) / '.graff' / 'traces').glob('*.jsonl'):
        for line in path.read_text(errors='replace').splitlines():
            try:
                row = json.loads(line)
                if isinstance(row, dict):
                    rows.append(row)
            except ValueError:
                continue
    api = [row for row in rows if row.get('ev') == 'api']
    roots = [row for row in api if row.get('agent') in ('main', 'repl')]
    pairs = sorted({(r['provider'], r['model']) for r in rows
                    if isinstance(r.get('provider'), str) and isinstance(r.get('model'), str)})
    valid = bool(roots) and all(r.get('model') == model for r in roots)
    if pairs:
        valid = valid and all(p == provider for p, _ in pairs)
    # Provider isolation is the admission guarantee; trace identity corroborates
    # it where the old binary emits it. Missing root API rows never qualify.
    return {'routing_ok': valid, 'observed_provider_models': pairs,
            'observed_root_models': sorted({r.get('model', '') for r in roots}),
            'trace_api_calls': len(api), 'provider_evidence': 'trace+isolated-credential' if pairs else 'isolated-credential'}


def provider_command(command):
    """Both arms use saved explicit provider/model through production startup."""
    result = []
    skip = False
    for arg in command:
        if skip:
            skip = False
            continue
        if arg == '--model':
            skip = True
            continue
        result.append(arg)
    return result


# Caches and dependency trees hold no task verifier; walking them is slow.
_NOT_VERIFIERS = {'.git', '.zig-cache', 'zig-cache', 'zig-out', 'zig-pkg', 'node_modules', '__pycache__'}
_LIVE_TASK = re.compile(r'live_setup\.py"?\s+([\w.-]+)')


def is_visible_test(name):
    """A test or check file a task ships (`test_*.py`, `check_*.py`,
    `*_test.py`). In a copy of a Zig repository, a `test_` name is production
    code: `src/test_hooks.zig` is where a fix registers a new test file."""
    return name.endswith('.py') and (name.startswith(('test_', 'check_')) or name.endswith('_test.py'))


def verifier_snapshot(sandbox, task, task_root):
    """Visible tests are immutable; held-out graders stay outside agent cwd.
    A mined task's named test was appended to a source file the fix may also
    belong in, so that test's own text is protected, not the file."""
    snap = {}
    for root, dirs, files in os.walk(sandbox):
        dirs[:] = [d for d in dirs if d not in _NOT_VERIFIERS]
        for name in files:
            if is_visible_test(name):
                path = os.path.join(root, name)
                snap[path] = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    for relative in re.findall(r'\$TASK_ROOT/(hidden/[^\s"\x27;]+)', task.get('check', '')):
        path = Path(task_root) / relative
        snap[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    live = _LIVE_TASK.search(' '.join(task.get('setup', [])))
    if live:
        import live_setup
        case = live_setup.named_case(live.group(1))
        path = os.path.join(sandbox, case[0]) if case else None
        block = live_setup.test_block(Path(path).read_text(errors='replace'), case[1]) if path and os.path.exists(path) else None
        if block:
            snap[path] = {'contains': block}
    return snap


def verifiers_unchanged(snapshot):
    for path, want in snapshot.items():
        try:
            if isinstance(want, dict):
                # Read as the snapshot did: text with universal newlines, so a
                # CRLF checkout (Windows) matches its own protected block.
                if want['contains'] not in Path(path).read_text(errors='replace'):
                    return False
                continue
            data = Path(path).read_bytes()
        except OSError:
            return False
        if hashlib.sha256(data).hexdigest() != want:
            return False
    return True


def kill_session(sid):
    """SIGKILL every process still in a harness's session; returns how many.
    The harness runs in a session of its own. graff gives each shell job its
    own process group but not its own session, so killing the harness's group
    left a job behind (a hung test binary spun a core through later tasks).
    Session ids outlive reparenting, so orphans are still found here."""
    if os.name != 'posix' or sid <= 1:
        return 0
    listing = subprocess.run(['ps', '-axo', 'pid='], capture_output=True, text=True).stdout
    killed = 0
    for token in listing.split():
        pid = int(token)
        if pid == os.getpid():
            continue
        try:
            if os.getsid(pid) != sid:
                continue
            os.kill(pid, 9)
            killed += 1
        except OSError:
            continue
    return killed


def isolate_git(sandbox):
    """Give a sandbox its own repository, holding the task tree as one commit.
    Sandboxes sit inside this checkout. Without their own repository, `git
    status`, `git diff` and `git show HEAD:` there describe the checkout, not
    the task, and a `git stash` or `git checkout` would change the checkout. A
    task that made its own repository keeps it."""
    if os.path.exists(os.path.join(sandbox, '.git')):
        return
    git = ['git', '-c', 'user.name=eval', '-c', 'user.email=eval@localhost', '-c', 'commit.gpgsign=false',
           '-c', 'core.hooksPath=/dev/null', '-C', sandbox]
    subprocess.run(git + ['init', '-q', '-b', 'main'], check=True, capture_output=True)
    with open(os.path.join(sandbox, '.git', 'info', 'exclude'), 'a') as f:
        f.write('.zig-cache/\nzig-cache/\nzig-out/\nzig-pkg/\n.graff/\n.eval-*\n')
    subprocess.run(git + ['add', '-A'], check=True, capture_output=True)
    subprocess.run(git + ['commit', '-q', '--allow-empty', '--no-verify', '-m', 'task'], check=True, capture_output=True)
