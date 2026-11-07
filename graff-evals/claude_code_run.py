#!/usr/bin/env python3
"""Run Claude Code headless on one eval task and report like graff does.

usage: claude_code_run.py MODEL PROMPT     (cwd = the task sandbox)

`claude -p --output-format stream-json --verbose`, permissions skipped, with
the task's `.mcp.json` as its only MCP config. The final result text goes to
stdout; a graff-format `[usage]` line goes to stderr. Calls are the API
responses (one message id each); tokens are the result event's session totals.
Anthropic's `input_tokens` leaves out cache reads and writes, so they are
added back to make the total prompt tokens. stdin is empty. Point Claude Code at an endpoint with the
usual environment (ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN).
"""
import json, os, subprocess, sys

CLAUDE = os.environ.get("CLAUDE_CODE_BIN", "claude")
model, prompt = sys.argv[1], sys.argv[2]

cmd = [CLAUDE, "-p", prompt, "--model", model, "--dangerously-skip-permissions",
       "--output-format", "stream-json", "--verbose"]
if os.path.exists(".mcp.json"):
    cmd += ["--mcp-config", ".mcp.json", "--strict-mcp-config"]
elif os.environ.get("CLAUDE_CODE_RUN_ISOLATED"):
    cmd += ["--strict-mcp-config"]
if os.environ.get("CLAUDE_CODE_RUN_ISOLATED"):
    # No user/project settings: hooks, plugins and permissions stay out.
    cmd += ["--setting-sources", ""]

r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
per_message, answer, result = {}, "", None
for line in r.stdout.splitlines():
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "assistant":
        msg = ev.get("message") or {}
        u = msg.get("usage") or {}
        key = msg.get("id") or f"anon-{len(per_message)}"
        prev = per_message.get(key, {})
        # Content blocks of one response arrive as separate events with the same id.
        per_message[key] = {k: max(int(u.get(k) or 0), int(prev.get(k) or 0))
                            for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")}
    elif ev.get("type") == "result":
        result = ev
        answer = ev.get("result") or answer
print(answer)
sys.stderr.write(r.stderr)
if result is not None and result.get("is_error"):
    sys.stderr.write(f"claude_code_run: result is_error ({result.get('subtype')})\n")
calls = len(per_message) or int((result or {}).get("num_turns") or 0)
# The result event carries the session's totals; per-message usage can be empty
# when a gateway streams it only at the end.
totals = (result or {}).get("usage") or {}
if totals:
    tin, tread, twrite, tout = (int(totals.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"))
else:
    tin = sum(m["input_tokens"] for m in per_message.values())
    tread = sum(m["cache_read_input_tokens"] for m in per_message.values())
    twrite = sum(m["cache_creation_input_tokens"] for m in per_message.values())
    tout = sum(m["output_tokens"] for m in per_message.values())
sys.stderr.write(f"\n[usage] {calls} api call(s) · {tin + tread + twrite} in ({tread} cached, {twrite} cache writes) + {tout} out tokens\n")
sys.exit(r.returncode)
