#!/usr/bin/env python3
"""#330 part 2: `graff serve` streams are sequenced, replayable, and resumable.

Five things are proven end-to-end against a scripted codex/Responses mock (no
network, no real provider):

1. every event of a turn carries a monotonic `seq`, contiguous from 1;
2. `GET /v1/sessions/<id>/events?from=N` after completion replays byte-identical
   events with no gaps and no duplicates;
3. a supervisor that drops the socket MID-TURN loses nothing: the bridge keeps
   draining the child into the persisted log, and `?from=N` delivers the tail;
4. killing the whole bridge and starting a REPLACEMENT process, then posting the
   same session name, continues the conversation - the mock sees turn one's
   history in turn three's request;
5. the sequence continues across that process boundary instead of restarting,
   so `?from=N` keeps meaning the same thing to the client.

Usage: python3 scripts/test-serve-resume.py [path/to/graff]
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from codex_ws_mock import CodexMock, RecordedRequest  # noqa: E402

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
SESSION = "e2e-resume"
SENTINEL = "TURN_ONE_SENTINEL"


# ── the mock ──────────────────────────────────────────────────────────────────


def reply(text: str, ordinal: int) -> list[dict]:
    return [
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message",
                "id": f"msg_{ordinal}",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            },
        },
        {
            "type": "response.completed",
            "response": {
                "id": f"resp_{ordinal}",
                "usage": {
                    "input_tokens": 100,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 10,
                    "total_tokens": 110,
                },
            },
        },
    ]


slow_turn = threading.Event()  # armed while the mid-stream-disconnect turn runs


def events_for_request(request: RecordedRequest) -> list[dict]:
    """Echo back exactly what history the model was handed, so the transcript
    itself proves whether context survived the process boundary."""
    body = json.dumps(request.body.get("input", []))
    if slow_turn.is_set():
        time.sleep(1.5)  # long enough for the client to walk away mid-turn
    return reply(
        f"call#{request.ordinal} items={len(request.body.get('input', []) or [])} "
        f"saw_sentinel={SENTINEL in body}",
        request.ordinal,
    )


# ── process + HTTP plumbing ───────────────────────────────────────────────────


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def environment(tmp: str, mock_port: int) -> dict[str, str]:
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home, exist_ok=True)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "resume-mock", "account_id": "acct"}}, fh)
    harness_dir = os.path.join(tmp, ".harness")
    os.makedirs(harness_dir, exist_ok=True)
    with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)
    env = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith("GRAFF_") and not k.startswith("CODEX_")
    }
    env.update(
        {
            "HOME": tmp,
            "CODEX_HOME": codex_home,
            "GRAFF_CODEX_URL": f"http://127.0.0.1:{mock_port}/backend-api/codex/responses",
            "GRAFF_CODEX_WS": "off",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
            "GRAFF_LEARN_AUTO": "off",
        }
    )
    return env


def start_serve(tmp: str, mock_port: int, port: int) -> subprocess.Popen:
    proc = subprocess.Popen(
        [GRAFF, "serve", "--host", "127.0.0.1", "--port", str(port),
         "--model", "codex", "--yolo", "--no-telemetry"],
        cwd=tmp,
        env=environment(tmp, mock_port),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    threading.Thread(target=lambda: [None for _ in proc.stderr], daemon=True).start()
    for _ in range(200):
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            conn.request("GET", "/healthz")
            if conn.getresponse().status == 200:
                conn.close()
                return proc
        except OSError:
            time.sleep(0.05)
    raise AssertionError("graff serve never became healthy")


def post_json(port: int, path: str, body: dict) -> dict:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    conn.request("POST", path, json.dumps(body), {"content-type": "application/json"})
    resp = conn.getresponse()
    payload = json.loads(resp.read())
    conn.close()
    return payload


def stream(port: int, method: str, path: str, body: dict | None = None,
           stop_after: int | None = None) -> list[dict]:
    """Read an NDJSON stream. stop_after=N closes the socket after N events -
    that is a supervisor crashing mid-turn, not a graceful end."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    payload = None if body is None else json.dumps(body)
    conn.request(method, path, payload, {"content-type": "application/json"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise AssertionError(f"{method} {path} -> {resp.status}: {resp.read()[:200]!r}")
    out: list[dict] = []
    try:
        while True:
            line = resp.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
            if stop_after is not None and len(out) >= stop_after:
                break
    finally:
        conn.close()  # mid-stream: this is the disconnect under test
    return out


# ── assertions ────────────────────────────────────────────────────────────────


def seqs(events: list[dict]) -> list[int]:
    for ev in events:
        if "seq" not in ev:
            raise AssertionError(f"event without a seq: {ev!r}")
    return [ev["seq"] for ev in events]


def expect_contiguous(events: list[dict], start: int, label: str) -> int:
    got = seqs(events)
    want = list(range(start, start + len(got)))
    if got != want:
        raise AssertionError(f"{label}: seq not contiguous from {start}: {got}")
    if len(set(got)) != len(got):
        raise AssertionError(f"{label}: duplicate seq: {got}")
    return got[-1] if got else start - 1


def final_text(events: list[dict]) -> str:
    if events[-1].get("type") != "turn":
        raise AssertionError(f"turn did not terminate cleanly: {events[-1]!r}")
    return events[-1]["text"]


def main() -> None:
    tmp = tempfile.mkdtemp(prefix="graff-serve-resume-")
    mock = CodexMock(events_for_request=events_for_request)
    mock_port = mock.start()
    serve_port = free_port()
    serve = start_serve(tmp, mock_port, serve_port)
    try:
        # 1 ── create a durable session and run a turn ────────────────────────
        created = post_json(serve_port, "/v1/sessions", {"session": SESSION})
        assert created == {"session_id": SESSION, "resumed": False, "last_seq": 0}, created

        first = stream(serve_port, "POST", f"/v1/sessions/{SESSION}",
                       {"type": "user", "text": SENTINEL})
        last = expect_contiguous(first, 1, "turn one")
        text_one = final_text(first)
        print(f"  turn 1: {len(first)} events, seq 1..{last} -> {text_one!r}")

        # 2 ── replay after completion is byte-identical, no gaps, no dupes ───
        replay_all = stream(serve_port, "GET", f"/v1/sessions/{SESSION}/events?from=1")
        if replay_all != first:
            raise AssertionError("full replay did not match the live stream")
        mid = last // 2 + 1
        replay_tail = stream(serve_port, "GET", f"/v1/sessions/{SESSION}/events?from={mid}")
        if replay_tail != [e for e in first if e["seq"] >= mid]:
            raise AssertionError("?from=N replayed the wrong slice")
        expect_contiguous(replay_tail, mid, "replay tail")
        past_end = stream(serve_port, "GET", f"/v1/sessions/{SESSION}/events?from={last + 1}")
        if past_end:
            raise AssertionError(f"replay past the tape invented events: {past_end!r}")
        print(f"  replay: from=1 identical ({len(replay_all)}), from={mid} exact tail "
              f"({len(replay_tail)}), from={last + 1} empty")

        # 3 ── drop the socket mid-turn; the run continues, ?from=N catches up ─
        slow_turn.set()
        partial: list[dict] = []
        runner = threading.Thread(
            target=lambda: partial.extend(
                stream(serve_port, "POST", f"/v1/sessions/{SESSION}",
                       {"type": "user", "text": "TURN_TWO"}, stop_after=2)))
        runner.start()
        runner.join(timeout=30)
        expect_contiguous(partial, last + 1, "turn two (before the crash)")
        seen = partial[-1]["seq"]
        rest = stream(serve_port, "GET", f"/v1/sessions/{SESSION}/events?from={seen + 1}")
        slow_turn.clear()
        last = expect_contiguous(rest, seen + 1, "turn two (after reconnect)")
        text_two = final_text(rest)
        if any(e["seq"] <= seen for e in rest):
            raise AssertionError("reconnect re-delivered events the client already had")
        print(f"  mid-stream: client died after seq {seen}; reconnect delivered "
              f"seq {seen + 1}..{last} -> {text_two!r}")

        # 4+5 ── kill the bridge, resume on a REPLACEMENT process ─────────────
        serve.kill()
        serve.wait(timeout=30)
        serve_port_2 = free_port()
        serve = start_serve(tmp, mock_port, serve_port_2)
        resumed = post_json(serve_port_2, "/v1/sessions", {"session": SESSION})
        if not resumed["resumed"] or resumed["session_id"] != SESSION:
            raise AssertionError(f"replacement bridge did not resume: {resumed!r}")
        if resumed["last_seq"] != last:
            raise AssertionError(
                f"replacement bridge lost the tape end: {resumed['last_seq']} != {last}")

        third = stream(serve_port_2, "POST", f"/v1/sessions/{SESSION}",
                       {"type": "user", "text": "TURN_THREE"})
        last_3 = expect_contiguous(third, last + 1, "turn three (replacement process)")
        text_three = final_text(third)
        if "saw_sentinel=True" not in text_three:
            raise AssertionError(
                f"model context did NOT carry over into the replacement process: {text_three!r}")
        items = int(text_three.split("items=")[1].split()[0])
        if items < 5:
            raise AssertionError(f"resumed history is too short to be turns 1-2: {text_three!r}")
        print(f"  replacement bridge: resumed={resumed['resumed']} last_seq={resumed['last_seq']}, "
              f"turn 3 seq {last + 1}..{last_3} -> {text_three!r}")

        # the whole tape, across both processes, is one gap-free sequence
        log = os.path.join(tmp, ".graff", "serve", f"{SESSION}.events.jsonl")
        with open(log, encoding="utf-8") as fh:
            tape = [json.loads(l) for l in fh if l.strip()]
        expect_contiguous(tape, 1, "persisted tape")
        print(f"  persisted tape: {len(tape)} events, seq 1..{tape[-1]['seq']}, no gaps")

        # The autosave lands just after the terminal event the HTTP response
        # ended on, so poll rather than race the child's own write.
        session_file = os.path.join(tmp, ".graff", "sessions", f"{SESSION}.session.json")
        saved: dict = {}
        for _ in range(100):
            with open(session_file, encoding="utf-8") as fh:
                saved = json.load(fh)
            if saved.get("event_seq", 0) >= last_3:
                break
            time.sleep(0.1)
        if saved.get("event_seq", 0) < last_3:
            raise AssertionError(f"session file did not persist the sequence: {saved.get('event_seq')}")
        print(f"  session file: event_seq={saved['event_seq']}, {len(saved['messages'])} messages")
        print("ok    serve streams are sequenced, replayable, and resumable across processes")
    finally:
        try:
            serve.kill()
            serve.wait(timeout=10)
        except Exception:
            pass
        mock.stop()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
