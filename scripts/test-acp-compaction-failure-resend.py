#!/usr/bin/env python3
"""#1930: a forced compaction that gave up on transport is not followed by a
second full-size request with a fresh retry ladder.

Against a scripted loopback codex Responses mock (SSE), with fake credentials:

1. the first reply carries an opaque compaction item, as an in-stream
   compaction would; later replies report usage at 97% of the window;
2. once history is anchored on that item and the meter is near the wall,
   the pre-send gate forces an in-stream compaction (threshold 1000);
3. from that request on the mock drops every connection, an outage that
   does not depend on the payload.

Expected (ADR 0356): once the compaction request has exhausted its transport
retries, the turn ends with a compaction-failed error. It does not send the
essentially unchanged answer request again under a reset retry budget, and
nothing else is sent after the turn ends.

Usage: python3 scripts/test-acp-compaction-failure-resend.py [path/to/graff]
"""
import importlib.util, json, os, sys, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
from codex_ws_mock import CodexMock  # noqa: E402

spec = importlib.util.spec_from_file_location("reload_count", REPO / "scripts" / "test-acp-reload-compaction-count.py")
reload_count = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reload_count)
Acp, threshold = reload_count.Acp, reload_count.threshold

BLOB = "C" * 24_000


class Script:
    def __init__(self):
        self.emitted = False
        self.input_tokens = 10_000
        self.failing = False

    def raw(self, req):
        if threshold(req.body) == 1000:
            self.failing = True
        return b"" if self.failing else None  # close without a response

    def __call__(self, req):
        n = req.ordinal
        reply = {"type": "message", "id": f"msg_{n}", "status": "completed", "role": "assistant",
                 "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
        out = [reply]
        if not self.emitted:
            self.emitted = True
            out = [{"type": "compaction", "id": "cmp_1", "encrypted_content": BLOB}, reply]
        usage = {"input_tokens": self.input_tokens, "input_tokens_details": {"cached_tokens": 0},
                 "output_tokens": 1, "total_tokens": self.input_tokens + 1}
        events = [{"type": "response.output_item.done", "output_index": i, "item": it} for i, it in enumerate(out)]
        events.append({"type": "response.completed", "response": {"id": f"resp_{n}", "output": out, "usage": usage}})
        return events


def main():
    script = Script()
    mock = CodexMock(events_for_request=script, raw_for_request=script.raw)
    port = mock.start()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        home, cwd = tmp / "home", tmp / "work"
        cwd.mkdir(parents=True)
        (home / ".harness").mkdir(parents=True)
        (home / ".harness" / "settings.json").write_text(json.dumps({"ai_title": False, "skills": {"codedbpro": False}}))
        (tmp / "mcp.json").write_text('{"mcpServers":{}}')
        codex_home = home / "codex"
        codex_home.mkdir()
        (codex_home / "auth.json").write_text(json.dumps({"tokens": {"access_token": "mock", "account_id": "acct"}}))
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY") and not k.startswith(("GRAFF_", "CODEX_", "HARNESS_"))}
        env.update(HOME=str(home), NO_COLOR="1", GRAFF_FLEET="off", GRAFF_NO_TELEMETRY="1", GRAFF_LEARN_AUTO="off",
                   GRAFF_BEHAVIOR_UPLOAD="off", GRAFF_MCP_CONFIG=str(tmp / "mcp.json"), GRAFF_FLAKE_RETRY_MS="10",
                   CODEX_HOME=str(codex_home), GRAFF_CODEX_WS="off",
                   GRAFF_CODEX_URL=f"http://127.0.0.1:{port}/backend-api/codex/responses")
        acp = Acp(cwd, env, "codex/gpt-5.5")
        try:
            acp.request("initialize", {"protocolVersion": 1})
            sid = acp.request("session/new", {"cwd": str(cwd), "mcpServers": []})["result"]["sessionId"]
            _, size = acp.prompt(sid, "start")[-1]
            script.input_tokens = size * 97 // 100
            for text in ("second", "third"):
                acp.prompt(sid, text)
            assert not script.failing, "compaction was forced before history was anchored on the item"
            before = len(mock.recorded_requests())
            failed = acp.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "fourth"}]}, timeout=180)
            ended = len(mock.recorded_requests())
            time.sleep(1.0)  # anything sent after the turn ended (a post-failure compaction) would land here
            after = len(mock.recorded_requests()) - ended
        finally:
            acp.close()
            mock.stop()
    turn = mock.recorded_requests()[before:ended]
    forced = [q for q in turn if threshold(q.body) == 1000]
    first = turn.index(forced[0]) if forced else None
    resent = [q for q in turn[first:] if threshold(q.body) != 1000] if forced else []
    sizes = sorted({len(json.dumps(q.body)) for q in turn})
    summary = (f"turn sent {len(turn)} request(s): {len(forced)} forced-compaction attempt(s), then "
               f"{len(resent)} answer attempt(s) after the compaction failed; body sizes {sizes[0]}..{sizes[-1]} bytes; "
               f"prompt {'errored' if 'error' in failed else 'ended ' + str((failed.get('result') or {}).get('stopReason'))}")
    problems = []
    if not forced:
        problems.append("setup: the pre-send gate never forced a compaction")
    if resent:
        problems.append(f"after the forced compaction gave up, the turn resent the answer request {len(resent)} time(s)")
    if "error" not in failed and (failed.get("result") or {}).get("stopReason") == "end_turn":
        problems.append("the turn reported success during a total outage")
    elif "Context compaction failed" not in json.dumps(failed):
        problems.append(f"the turn did not end with the compaction-failed error: {json.dumps(failed)[:300]}")
    if after:
        problems.append(f"{after} request(s) went out after the failed turn ended")
    if problems and not forced:
        sys.exit("FAIL (setup) " + summary)
    if problems:
        print(f"FAIL (#1930): {summary}")
        for p in problems:
            print("  - " + p)
        sys.exit(1)
    print(f"ok (#1930): {summary}")


if __name__ == "__main__":
    main()
