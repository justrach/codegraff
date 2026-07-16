#!/usr/bin/env python3
"""Dependency-free fake Codex Responses backend for graff transport tests.

One TCP port serves both transports graff uses for codex turns:

- WebSocket (primary): a GET with ``Upgrade: websocket`` on a path ending in
  ``/responses`` is upgraded (101 + a properly computed Sec-WebSocket-Accept,
  even though graff's client does not check it). The mock then reads the
  client's MASKED ``{"type":"response.create",...}`` text frame (7/16/64-bit
  lengths, fragmentation tolerated) and answers with two UNMASKED text frames:
  ``response.output_item.done`` carrying the assistant message item, then
  ``response.completed`` carrying the fixed usage block.
- SSE (fallback): a plain POST to the same path gets a 200
  ``text/event-stream`` body carrying the SAME two events as ``data:`` lines.

The assistant item is shaped exactly the way stepResponses
(src/agent_steps.zig) surfaces reply text: a ``message`` item whose content
array holds an ``output_text`` block. ``ws_turns``/``sse_turns`` count which
transport actually served each turn so tests can prove no silent fallback.

Importable (``CodexMock().start() -> port`` / ``stop()``) and runnable:
``python3 scripts/codex_ws_mock.py [--port N]`` serves until Ctrl-C, tracing
events to stderr.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONT = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

# Defensive cap on one reassembled inbound message (mirrors ws.zig's 4 MiB,
# with headroom for large request bodies).
MESSAGE_CAP = 16 * 1024 * 1024

REPLY_TEXT = "pong from the mock"
USAGE = {
    "input_tokens": 1200,
    "input_tokens_details": {"cached_tokens": 0},
    "output_tokens": 300,
    "total_tokens": 1500,
}


def assistant_item() -> dict:
    """The message item stepResponses (src/agent_steps.zig) renders as reply
    text; role/id/status/annotations match real Responses output items so the
    item is also valid next-turn input."""
    return {
        "type": "message",
        "id": "msg_mock_1",
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": REPLY_TEXT, "annotations": []}],
    }


def turn_events(response_id: str = "resp_mock_1") -> list[dict]:
    """The two events one mocked turn produces, in send order."""
    return [
        {"type": "response.output_item.done", "item": assistant_item()},
        {
            "type": "response.completed",
            "response": {"id": response_id, "usage": dict(USAGE)},
        },
    ]


@dataclass
class Frame:
    opcode: int
    payload: bytes
    fin: bool


@dataclass(frozen=True)
class RecordedRequest:
    """One decoded Responses request, in server-observed order.

    ``connection_id`` is populated for WebSocket requests so tests can prove a
    post-compaction request re-anchored on a new socket. SSE requests use None.
    """

    ordinal: int
    transport: str
    connection_id: int | None
    body: dict


class _SockReader:
    """Buffered exact-read wrapper so bytes recv'd past a boundary (e.g. the
    HTTP head) still feed later frame/body reads."""

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._buf = bytearray()

    def read_exact(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("peer closed mid-read")
            self._buf.extend(chunk)
        out = bytes(self._buf[:n])
        del self._buf[:n]
        return out

    def read_until(self, delim: bytes) -> bytes:
        while delim not in self._buf:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("peer closed before delimiter")
            self._buf.extend(chunk)
        end = self._buf.index(delim) + len(delim)
        out = bytes(self._buf[:end])
        del self._buf[:end]
        return out


def _read_frame(reader: _SockReader) -> Frame:
    """Read one WebSocket frame; unmasks client (masked) payloads."""
    head = reader.read_exact(2)
    fin = bool(head[0] & 0x80)
    opcode = head[0] & 0x0F
    masked = bool(head[1] & 0x80)
    length = head[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", reader.read_exact(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", reader.read_exact(8))[0]
    if length > MESSAGE_CAP:
        raise ConnectionError(f"frame too long ({length}b)")
    mask = reader.read_exact(4) if masked else b""
    payload = reader.read_exact(length) if length else b""
    if masked and payload:
        payload = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
    return Frame(opcode, payload, fin)


def _send_frame(sock: socket.socket, opcode: int, payload: bytes) -> None:
    """Send one unmasked (server->client) frame with FIN set."""
    n = len(payload)
    if n < 126:
        header = bytes([0x80 | opcode, n])
    elif n <= 0xFFFF:
        header = bytes([0x80 | opcode, 126]) + struct.pack(">H", n)
    else:
        header = bytes([0x80 | opcode, 127]) + struct.pack(">Q", n)
    sock.sendall(header + payload)


def _read_message(reader: _SockReader, sock: socket.socket) -> Frame:
    """Reassemble one data message; answers ping inline, returns close as-is."""
    opcode: int | None = None
    parts: list[bytes] = []
    total = 0
    while True:
        frame = _read_frame(reader)
        if frame.opcode == OP_PING:
            _send_frame(sock, OP_PONG, frame.payload)
            continue
        if frame.opcode == OP_PONG:
            continue
        if frame.opcode == OP_CLOSE:
            return frame
        if frame.opcode != OP_CONT:
            opcode = frame.opcode
        total += len(frame.payload)
        if total > MESSAGE_CAP:
            raise ConnectionError("message too long")
        parts.append(frame.payload)
        if frame.fin:
            return Frame(
                opcode if opcode is not None else OP_TEXT, b"".join(parts), True
            )


def ws_accept_value(key: str) -> str:
    """RFC 6455 Sec-WebSocket-Accept for a client Sec-WebSocket-Key."""
    digest = hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


@dataclass
class CodexMock:
    """Threaded fake codex backend: start() binds and returns the real port,
    stop() tears it down. ws_turns/sse_turns count served turns per transport.

    ``events_for_request`` optionally scripts replies from the decoded request;
    the default remains the fixed mock reply used by the transport smoke tests.
    """

    host: str = "127.0.0.1"
    port: int = 0
    verbose: bool = False
    ws_turns: int = 0
    sse_turns: int = 0
    ws_connections: int = 0
    events_for_request: Callable[[RecordedRequest], list[dict]] | None = field(
        default=None, repr=False
    )
    requests: list[RecordedRequest] = field(default_factory=list, repr=False)
    _sock: socket.socket | None = field(default=None, repr=False)
    _threads: list[threading.Thread] = field(default_factory=list, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    _stopping: bool = field(default=False, repr=False)

    def start(self) -> int:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.host, self.port))
        srv.listen(8)
        self.port = srv.getsockname()[1]
        self._sock = srv
        acceptor = threading.Thread(target=self._accept_loop, daemon=True)
        acceptor.start()
        self._threads.append(acceptor)
        return self.port

    def stop(self) -> None:
        self._stopping = True
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        for thread in self._threads:
            thread.join(timeout=1.0)
        self._threads.clear()

    def recorded_requests(self) -> list[RecordedRequest]:
        """Return a stable snapshot for assertions after a scenario completes."""
        with self._lock:
            return list(self.requests)

    # ── internals ─────────────────────────────────────────────────────────

    def _log(self, message: str) -> None:
        if self.verbose:
            print(f"[codex-mock] {message}", file=sys.stderr, flush=True)

    def _events(
        self, transport: str, connection_id: int | None, body: dict
    ) -> list[dict]:
        with self._lock:
            request = RecordedRequest(
                ordinal=len(self.requests) + 1,
                transport=transport,
                connection_id=connection_id,
                body=body,
            )
            self.requests.append(request)
        if self.events_for_request is not None:
            return self.events_for_request(request)
        return turn_events(f"resp_mock_{request.ordinal}")

    def _accept_loop(self) -> None:
        srv = self._sock
        assert srv is not None
        while not self._stopping:
            try:
                conn, _addr = srv.accept()
            except OSError:
                return
            handler = threading.Thread(target=self._handle, args=(conn,), daemon=True)
            handler.start()
            self._threads.append(handler)

    def _handle(self, conn: socket.socket) -> None:
        try:
            conn.settimeout(60.0)
            reader = _SockReader(conn)
            head = reader.read_until(b"\r\n\r\n").decode("latin-1")
            request_line, _, header_block = head.partition("\r\n")
            parts = request_line.split()
            method, path = (parts + ["", ""])[:2]
            headers: dict[str, str] = {}
            for line in header_block.split("\r\n"):
                name, sep, value = line.partition(":")
                if sep:
                    headers[name.strip().lower()] = value.strip()
            bare_path = path.split("?", 1)[0]
            if (
                method == "GET"
                and headers.get("upgrade", "").lower() == "websocket"
                and bare_path.endswith("/responses")
            ):
                self._serve_ws(conn, reader, headers)
            elif method == "POST" and bare_path.endswith("/responses"):
                self._serve_sse(conn, reader, headers)
            else:
                self._log(f"http 404 {method} {path}")
                body = b"not found"
                conn.sendall(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: "
                    + str(len(body)).encode("ascii")
                    + b"\r\nConnection: close\r\n\r\n"
                    + body
                )
        except (ConnectionError, OSError) as exc:
            self._log(f"connection dropped: {exc}")
        finally:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()

    def _serve_ws(
        self, conn: socket.socket, reader: _SockReader, headers: dict[str, str]
    ) -> None:
        with self._lock:
            self.ws_connections += 1
            connection_id = self.ws_connections
        accept = ws_accept_value(headers.get("sec-websocket-key", ""))
        conn.sendall(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n"
                "\r\n"
            ).encode("ascii")
        )
        self._log(f"ws upgraded (connection {connection_id})")
        while True:
            message = _read_message(reader, conn)
            if message.opcode == OP_CLOSE:
                try:
                    _send_frame(conn, OP_CLOSE, b"")
                except OSError:
                    pass
                self._log("ws closed")
                return
            try:
                event = json.loads(message.payload.decode("utf-8"))
            except ValueError:
                event = None
            etype = event.get("type") if isinstance(event, dict) else None
            self._log(f"ws <- {etype} ({len(message.payload)}b)")
            if etype != "response.create":
                continue
            for ev in self._events("ws", connection_id, event):
                _send_frame(
                    conn, OP_TEXT, json.dumps(ev, separators=(",", ":")).encode("utf-8")
                )
                self._log(f"ws -> {ev['type']}")
            with self._lock:
                self.ws_turns += 1

    def _serve_sse(
        self, conn: socket.socket, reader: _SockReader, headers: dict[str, str]
    ) -> None:
        length = int(headers.get("content-length", "0") or 0)
        body = reader.read_exact(length) if length else b""
        self._log(f"sse <- POST ({len(body)}b)")
        try:
            parsed = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            parsed = {}
        if not isinstance(parsed, dict):
            parsed = {}
        events = self._events("sse", None, parsed)
        payload = "".join(
            f"data: {json.dumps(ev, separators=(',', ':'))}\n\n" for ev in events
        ).encode("utf-8")
        conn.sendall(
            (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream\r\n"
                f"Content-Length: {len(payload)}\r\n"
                "Connection: close\r\n"
                "\r\n"
            ).encode("ascii")
            + payload
        )
        for ev in events:
            self._log(f"sse -> {ev['type']}")
        with self._lock:
            self.sse_turns += 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fake codex Responses backend (WebSocket + SSE) for manual debugging."
    )
    parser.add_argument(
        "--port", type=int, default=0, help="TCP port to bind (default: ephemeral)"
    )
    args = parser.parse_args()
    mock = CodexMock(port=args.port, verbose=True)
    port = mock.start()
    print(
        f"codex mock listening on 127.0.0.1:{port} "
        f"(GRAFF_CODEX_URL=http://127.0.0.1:{port}/backend-api/codex/responses)",
        file=sys.stderr,
        flush=True,
    )
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        mock.stop()


if __name__ == "__main__":
    main()
