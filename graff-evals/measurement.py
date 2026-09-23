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
    for key, pattern in [('sub_calls', r'(\d+) subscription call'), ('unpriced_calls', r'(\d+) call\(s\) on unpriced models')]:
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
    if subtotal or result.get('missing_usage_calls') or result.get('unreported_failed_attempts'):
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
    empty_mcp = home / 'empty-mcp.json'
    empty_mcp.write_text('{"mcpServers":{}}')
    env = {k: source[k] for k in ('PATH', 'LANG', 'LC_ALL', 'SDKROOT', 'DEVELOPER_DIR', 'SYSTEMROOT') if k in source}
    value = str(Path(source[credential]).expanduser().resolve()) if provider == 'codex' else source[credential]
    env.update({credential: value, 'HOME': str(home), 'USERPROFILE': str(home),
                'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                'PWD': sandbox, 'GRAFF_MCP_CONFIG': str(empty_mcp), 'GRAFF_FLEET': 'off',
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
    roots = [row for row in api if row.get('agent') == 'main']
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


def verifier_snapshot(sandbox, task, task_root):
    """Visible tests are immutable; held-out graders stay outside agent cwd."""
    paths = {p for p in Path(sandbox).rglob('*') if p.is_file() and
             (p.name.startswith('test_') or p.name.startswith('check_') or p.name.endswith('_test.py'))}
    for relative in re.findall(r'\$TASK_ROOT/(hidden/[^\s"\x27;]+)', task.get('check', '')):
        paths.add(Path(task_root) / relative)
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def verifiers_unchanged(snapshot):
    for path, digest in snapshot.items():
        try:
            if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
                return False
        except OSError:
            return False
    return True
