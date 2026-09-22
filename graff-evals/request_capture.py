"""Opt-in private body evidence; component fingerprints do not prove cache hits."""
import hashlib
import json
import re
from pathlib import Path


def directory(sandbox):
    path = Path(sandbox)
    return path.parent.parent / 'requests' / path.name


def configure(env, sandbox):
    target = directory(sandbox)
    target.parent.mkdir(mode=0o700, exist_ok=True)
    target.mkdir(mode=0o700, exist_ok=False)
    env.update(GRAFF_REQ_STATS='1', GRAFF_REQ_DUMP_DIR=str(target.resolve()))


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def receipt(sandbox):
    target = directory(sandbox)
    rows = []
    for path in target.rglob('body-*.json'):
        match = re.fullmatch(r'body-([0-9]+)\.json', path.name)
        sequence = int(match.group(1)) if match else None
        row = {'file': str(path.relative_to(target)),
               'run_id': str(path.parent.relative_to(target)), 'sequence': sequence}
        try:
            if sequence is None or sequence < 1:
                raise ValueError('capture filename must have a positive sequence')
            raw = path.read_bytes()
            row.update(body_bytes=len(raw), body_sha256=hashlib.sha256(raw).hexdigest())
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise ValueError('request body is not an object')
            if 'instructions' in body:
                instructions = body['instructions']
            elif 'system' in body:
                instructions = body['system']
            else:
                instructions = []
                for message in body.get('messages', []):
                    if message.get('role') not in ('system', 'developer'):
                        break
                    instructions.append(message)
            row.update(model=body.get('model'),
                       instructions_sha256=digest(instructions),
                       tools_sha256=digest(body.get('tools')),
                       prefix_components_sha256=digest([instructions, body.get('tools')]),
                       cache_key_sha256=digest(body['prompt_cache_key']) if 'prompt_cache_key' in body else None,
                       chained=bool(body.get('previous_response_id')))
        except (OSError, ValueError, TypeError, AttributeError) as error:
            row['capture_error'] = str(error)
        rows.append(row)
    # Sequence describes body construction within one process. Random run ids
    # cannot order separate processes, and transport retries may reuse a body.
    rows.sort(key=lambda r: (r['run_id'], r['sequence'] if r['sequence'] is not None else -1, r['file']))
    issues = []
    if not rows:
        issues.append('no_captured_bodies')
    if any('capture_error' in row for row in rows):
        issues.append('unreadable_or_invalid_capture')
    sequences = {}
    for row in rows:
        sequences.setdefault(row['run_id'], []).append(row['sequence'])
    for run_id, seq in sequences.items():
        if seq != list(range(1, len(seq) + 1)):
            issues.append(f'noncontiguous_sequence:{run_id}')
    return {'request_capture': {'enabled': True, 'count': len(rows),
                               'valid_count': sum('capture_error' not in r for r in rows),
                               'capture_evidence_ok': not issues, 'integrity_issues': issues,
                               'order_scope': 'per_run_body_build', 'requests': rows,
                               'meaning': 'nonempty parseable contiguous captured bodies, not completeness of HTTP attempts; component fingerprints do not prove cache reuse'}}
