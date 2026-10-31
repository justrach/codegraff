#!/usr/bin/env python3
"""Claude Agent (ADR 0309) end to end against a fake `claude`, offline.

The fake speaks the Agent SDK control protocol the way `claude` 2.1.x does:
it answers `initialize`, lists graff's tools over the tunnelled MCP server,
streams a response that calls `write_file`, holds the call until graff's own
loop has run it, then answers. Asserts:

- graff's tools reach the model as the `graff` SDK server; the user line is
  client-composed and graff's system prompt replaces Claude Code's
- the held `tools/call` is answered with graff's real result, matched by
  `_meta["claudecode/toolUseId"]`, and the file graff wrote exists
- the second step reuses the same `claude` process (one spawn per run)
- Claude Code's own login is never read: the fake sees no graff credential
"""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

FAKE = r'''#!/usr/bin/env python3
import json, os, sys
log = open(os.environ["FAKE_CLAUDE_LOG"], "a")
def note(kind, obj): log.write(json.dumps({"kind": kind, "obj": obj}) + "\n"); log.flush()
note("argv", sys.argv[1:])
note("env", {k: v for k, v in os.environ.items() if k.startswith("CLAUDE") or k in ("MCP_TOOL_TIMEOUT", "DISABLE_AUTO_COMPACT")})
def out(obj): sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
def read():
    line = sys.stdin.readline()
    if not line: sys.exit(0)
    obj = json.loads(line); note("in", obj); return obj
def ev(e): out({"type": "stream_event", "parent_tool_use_id": None, "event": e})
def mcp(rid, msg):
    out({"type": "control_request", "request_id": rid, "request": {"subtype": "mcp_message", "server_name": "graff", "message": msg}})
    return read()
init = read()
# As claude does: connect the SDK server before answering initialize.
mcp("m1", {"method": "initialize", "params": {"protocolVersion": "2025-11-25"}, "jsonrpc": "2.0", "id": 0})
mcp("m2", {"method": "tools/list", "jsonrpc": "2.0", "id": 1})
out({"type": "control_response", "response": {"subtype": "success", "request_id": init["request_id"], "response": {"claude_code_version": "2.1.304", "models": []}}})
user = read()
usage = {"input_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 1}
ev({"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-test", "content": [], "usage": usage}})
ev({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_1", "name": "mcp__graff__write_file", "input": {}}})
ev({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps({"path": "out.txt", "content": "from claude agent\n"})}})
ev({"type": "content_block_stop", "index": 0})
ev({"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {"output_tokens": 20}})
ev({"type": "message_stop"})
reply = mcp("m3", {"method": "tools/call", "params": {"name": "write_file", "arguments": {"path": "out.txt", "content": "from claude agent\n"}, "_meta": {"claudecode/toolUseId": "toolu_1"}}, "jsonrpc": "2.0", "id": 2})
ev({"type": "message_start", "message": {"id": "msg_2", "type": "message", "role": "assistant", "model": "claude-test", "content": [], "usage": usage}})
ev({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
ev({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "FAKE-DONE"}})
ev({"type": "content_block_stop", "index": 0})
ev({"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 3}})
ev({"type": "message_stop"})
out({"type": "result", "subtype": "success", "is_error": False, "result": "FAKE-DONE"})
while True: read()
'''


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    if os.name == 'nt':
        print('SKIP claude-agent fake child needs a POSIX shebang', flush=True)
        return
    temp = Path(tempfile.mkdtemp(prefix='graff-claude-agent-'))
    try:
        fake = temp / 'bin' / 'claude'
        fake.parent.mkdir()
        fake.write_text(FAKE)
        fake.chmod(0o755)
        log = temp / 'fake.log'
        work = temp / 'proj'
        work.mkdir()
        mcp_off = temp / 'mcp.json'
        mcp_off.write_text('{"mcpServers": {}}')
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and not k.startswith('CLAUDE')}
        env.update(HOME=str(temp), USERPROFILE=str(temp), GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1',
                   GRAFF_NO_CODEDB_GUARD='1', GRAFF_MCP_CONFIG=str(mcp_off), GRAFF_CLAUDE_AGENT='1',
                   GRAFF_CLAUDE_PATH=str(fake), FAKE_CLAUDE_LOG=str(log),
                   # An enclosing Claude Code session's identity must not reach the child.
                   CLAUDECODE='1', CLAUDE_CODE_ENTRYPOINT='cli', CLAUDE_CONFIG_DIR=str(temp / 'cc'))
        run = subprocess.run([binary, '--model', 'claude-agent/sonnet', '--yolo', '-p', 'write the file'], cwd=work, env=env,
                             capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
        assert run.returncode == 0, run.stderr[-2000:]
        assert 'FAKE-DONE' in run.stdout, (run.stdout[-500:], run.stderr[-1500:])
        assert (work / 'out.txt').read_text() == 'from claude agent\n'
        rows = [json.loads(l) for l in log.read_text().splitlines() if l.strip()]
        spawns = [r['obj'] for r in rows if r['kind'] == 'argv']
        assert len(spawns) == 1, f'expected one claude process, got {len(spawns)}'
        argv = spawns[0]
        assert argv[argv.index('--tools') + 1] == '' and argv[argv.index('--allowedTools') + 1] == 'mcp__graff__*', argv
        assert argv[argv.index('--model') + 1] == 'sonnet' and '--no-session-persistence' in argv, argv
        child_env = [r['obj'] for r in rows if r['kind'] == 'env'][0]
        assert 'CLAUDECODE' not in child_env and 'CLAUDE_CODE_ENTRYPOINT' not in child_env, child_env
        assert child_env.get('CLAUDE_CONFIG_DIR') == str(temp / 'cc'), child_env
        assert child_env.get('DISABLE_AUTO_COMPACT') == '1', child_env
        inputs = [r['obj'] for r in rows if r['kind'] == 'in']
        init = inputs[0]['request']
        assert init['subtype'] == 'initialize' and init['sdkMcpServers'] == ['graff'], init
        assert init['systemPrompt'] and 'appendSystemPrompt' not in init, init
        replies = {i['response']['request_id']: i['response'] for i in inputs if i.get('type') == 'control_response'}
        listed = replies['m2']['response']['mcp_response']['result']['tools']
        assert any(t['name'] == 'write_file' and 'inputSchema' in t for t in listed), [t['name'] for t in listed]
        user = [i for i in inputs if i.get('type') == 'user'][0]
        assert user['client_composed'] is True and user['message']['content'][0]['text'] == 'write the file', user
        call = replies['m3']['response']['mcp_response']
        assert call['id'] == 2 and not call['result'].get('isError'), call
        assert 'out.txt' in call['result']['content'][0]['text'], call
        print('PASS claude-agent: graff tools as the SDK server, a held call answered with graff\'s result, one process', flush=True)
    finally:
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
