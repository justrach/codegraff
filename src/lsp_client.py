"""One-shot stdio LSP transport, embedded by lsp.zig (Python 3.9+).

Invocation: python3 -c <this source> <JSON request>. stdout is one JSON reply.
The caller supplies trusted argv and a scrubbed environment. No shell is used.
The server stays in the caller-owned process group: process_runner must use
kill_process_tree=true, including cancellation, to reap server descendants.
"""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
from urllib.parse import unquote, urlsplit

MAX_SOURCE = 1024 * 1024
MAX_MESSAGE = 4 * 1024 * 1024
MAX_HEADER = 8192
MAX_STDOUT = 8 * 1024 * 1024
MAX_STDERR = 256 * 1024
MAX_EVENTS = 256
OPERATIONS = {
    "hover": "textDocument/hover",
    "definition": "textDocument/definition",
    "references": "textDocument/references",
    "document_symbols": "textDocument/documentSymbol",
    "diagnostics": "textDocument/diagnostic",
}


class Failure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def fail(code, message):
    raise Failure(code, message)


def strict_json(data):
    def constant(_):
        fail("protocol_error", "Non-finite JSON number")
    try:
        return json.loads(data, parse_constant=constant)
    except (ValueError, UnicodeError, RecursionError):
        fail("protocol_error", "Invalid JSON message")


def read_frame(stream, budget=None):
    """Read one bounded LSP frame; EOF between frames is distinct from truncation."""
    header = bytearray()
    while not header.endswith(b"\r\n\r\n"):
        byte = stream.read(1)
        if not byte:
            if not header:
                return None
            fail("protocol_error", "Truncated LSP header")
        header.extend(byte)
        if len(header) > MAX_HEADER:
            fail("limit_exceeded", "LSP header limit exceeded")
    lengths = []
    for line in bytes(header[:-4]).split(b"\r\n"):
        name, separator, value = line.partition(b":")
        if not separator:
            fail("protocol_error", "Malformed LSP header")
        if name.strip().lower() == b"content-length":
            value = value.strip()
            if not value or not value.isdigit() or len(value) > 10:
                fail("protocol_error", "Invalid Content-Length")
            lengths.append(int(value))
    if len(lengths) != 1:
        fail("protocol_error", "Expected one Content-Length")
    length = lengths[0]
    if length <= 0 or length > MAX_MESSAGE:
        fail("limit_exceeded", "LSP message limit exceeded")
    if budget is not None:
        budget[0] += len(header) + length
        if budget[0] > MAX_STDOUT:
            fail("limit_exceeded", "LSP stdout limit exceeded")
    body = bytearray()
    while len(body) < length:
        part = stream.read(length - len(body))
        if not part:
            fail("protocol_error", "Truncated LSP body")
        body.extend(part)
    message = strict_json(bytes(body))
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        fail("protocol_error", "Expected JSON-RPC 2.0 object")
    return message


def encode_frame(message):
    body = json.dumps(message, ensure_ascii=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")
    if len(body) > MAX_MESSAGE:
        fail("limit_exceeded", "Outgoing LSP message limit exceeded")
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


def validate(request):
    if not isinstance(request, dict):
        fail("invalid_request", "Expected request object")
    command = request.get("command")
    if (not isinstance(command, list) or not command or len(command) > 64 or
            any(not isinstance(s, str) or not s or "\0" in s for s in command) or
            sum(len(s) for s in command) > 32768):
        fail("invalid_request", "Expected bounded nonempty command argv")
    operation = request.get("operation")
    if not isinstance(operation, str) or operation not in OPERATIONS:
        fail("invalid_request", "Unsupported LSP operation")
    timeout = request.get("timeout_ms", 5000)
    if type(timeout) is not int or not 1 <= timeout <= 30000:
        fail("invalid_request", "timeout_ms must be between 1 and 30000")
    language = request.get("language_id")
    if not isinstance(language, str) or not 1 <= len(language) <= 128:
        fail("invalid_request", "Expected language_id")
    try:
        root, path = Path(request["root"]), Path(request["path"])
        if not root.is_absolute() or not path.is_absolute():
            raise ValueError()
        root, path = root.resolve(strict=True), path.resolve(strict=True)
        path.relative_to(root)
        if not root.is_dir() or not path.is_file():
            raise ValueError()
        with path.open("rb") as source:
            raw = source.read(MAX_SOURCE + 1)
        if len(raw) > MAX_SOURCE:
            fail("limit_exceeded", "Source exceeds 1 MiB")
        text = raw.decode("utf-8")
    except (KeyError, TypeError, ValueError, OSError, RuntimeError):
        fail("invalid_request", "Expected existing UTF-8 source inside workspace root")
    if operation in ("hover", "definition", "references"):
        line, character = request.get("line"), request.get("character")
        if type(line) is not int or type(character) is not int or min(line, character) < 0:
            fail("invalid_request", "Expected zero-based UTF-16 line and character")
        lines = text.split("\n")
        if line >= len(lines):
            fail("invalid_request", "Position is outside document")
        content = lines[line].rstrip("\r")
        units = 0
        boundaries = {0}
        for char in content:
            units += 2 if ord(char) > 0xFFFF else 1
            boundaries.add(units)
        if character not in boundaries:
            fail("invalid_request", "Position is not a UTF-16 character boundary")
    return command, root, path, text, timeout


def filter_locations(value, root, removed, depth=0):
    """Drop external/non-file Locations, Links and SymbolInformation locations."""
    if depth > 64:
        fail("limit_exceeded", "LSP reply nesting limit exceeded")
    if isinstance(value, list):
        return [item for item in (filter_locations(v, root, removed, depth + 1) for v in value)
                if item is not _EXTERNAL]
    if not isinstance(value, dict):
        return value
    for key in ("uri", "targetUri"):
        if key not in value:
            continue
        try:
            if not isinstance(value[key], str):
                raise ValueError()
            parsed = urlsplit(value[key])
            if parsed.scheme != "file" or parsed.netloc not in ("", "localhost") or parsed.query or parsed.fragment:
                raise ValueError()
            decoded = unquote(parsed.path, errors="strict")
            if os.name == "nt" and len(decoded) > 2 and decoded[0] == "/" and decoded[2] == ":":
                decoded = decoded[1:]
            path = Path(decoded)
            if not path.is_absolute():
                raise ValueError()
            path.resolve().relative_to(root)
        except (TypeError, ValueError, OSError, RuntimeError):
            removed[0] += 1
            return _EXTERNAL
    result = {}
    for key, child in value.items():
        filtered = filter_locations(child, root, removed, depth + 1)
        if filtered is _EXTERNAL:
            if key == "location":
                return _EXTERNAL
        else:
            result[key] = filtered
    return result


_EXTERNAL = object()


class Client:
    def __init__(self, command, root, deadline, new_session=False):
        self.deadline = deadline
        self.events = queue.Queue(maxsize=16)
        self.writes = queue.Queue(maxsize=4)
        self.stop = threading.Event()
        self.count = 0
        self.diagnostics = None
        self.uri = None
        self.pending = None
        self.read_budget = [0]
        # Do not detach: the embedding process runner owns descendant cleanup.
        self.proc = subprocess.Popen(command, cwd=str(root), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=new_session)
        self.threads = [threading.Thread(target=fn, daemon=True)
                        for fn in (self._read, self._stderr, self._write)]
        for thread in self.threads:
            thread.start()

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            fail("timeout", "Language server timed out; result is not ready")
        return remaining

    def _put(self, event):
        while not self.stop.is_set():
            try:
                self.events.put(event, timeout=0.05)
                return
            except queue.Full:
                pass

    def _read(self):
        try:
            while not self.stop.is_set():
                message = read_frame(self.proc.stdout, self.read_budget)
                self._put(("message", message))
                if message is None:
                    return
        except Failure as error:
            self._put(("failure", error))
        except (OSError, ValueError):
            self._put(("failure", Failure("transport_error", "Server stdout read failed")))

    def _stderr(self):
        try:
            total = 0
            while not self.stop.is_set():
                chunk = self.proc.stderr.read(4096)
                if not chunk:
                    return
                total += len(chunk)
                if total > MAX_STDERR:
                    self._put(("failure", Failure("limit_exceeded", "LSP stderr limit exceeded")))
                    return
        except (OSError, ValueError):
            pass

    def _write(self):
        while not self.stop.is_set():
            try:
                item = self.writes.get(timeout=0.05)
            except queue.Empty:
                continue
            if item is None:
                return
            frame, done, errors = item
            try:
                self.proc.stdin.write(frame)
                self.proc.stdin.flush()
            except (OSError, ValueError):
                errors.append(True)
            finally:
                done.set()

    def send(self, message):
        done, errors = threading.Event(), []
        try:
            self.writes.put((encode_frame(message), done, errors), timeout=self.remaining())
        except queue.Full:
            fail("timeout", "Language server is not reading requests")
        if not done.wait(self.remaining()):
            fail("timeout", "Language server is not reading requests")
        if errors:
            fail("transport_error", "Server stdin write failed")

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, request_id, method, params):
        self.pending = request_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})

    def event(self):
        try:
            kind, value = self.events.get(timeout=self.remaining())
        except queue.Empty:
            fail("timeout", "Language server timed out; result is not ready")
        if kind == "failure":
            raise value
        if value is None:
            fail("server_exited", "Language server exited before completing the operation")
        self.count += 1
        if self.count > MAX_EVENTS:
            fail("limit_exceeded", "LSP event limit exceeded")
        if "method" in value:
            method, params = value["method"], value.get("params", {})
            if "id" in value:
                self._server_request(value)
            elif method == "textDocument/publishDiagnostics" and isinstance(params, dict):
                if params.get("uri") == self.uri and params.get("version", 1) in (None, 1):
                    diagnostics = params.get("diagnostics")
                    if not isinstance(diagnostics, list):
                        fail("protocol_error", "Invalid diagnostics notification")
                    self.diagnostics = diagnostics
            return None
        return value

    def _server_request(self, message):
        method, params = message["method"], message.get("params", {})
        response = {"jsonrpc": "2.0", "id": message["id"]}
        if method == "workspace/configuration" and isinstance(params, dict):
            items = params.get("items", [])
            if not isinstance(items, list) or len(items) > 256:
                fail("protocol_error", "Invalid configuration request")
            response["result"] = [None] * len(items)
        elif method == "workspace/workspaceFolders":
            response["result"] = None
        elif method == "window/workDoneProgress/create":
            response["result"] = None
        else:
            # No edits, commands, dynamic registrations or UI are performed.
            response["error"] = {"code": -32601, "message": "Method not supported"}
        self.send(response)

    def response(self, request_id):
        while True:
            message = self.event()
            if message is None or message.get("id") != request_id:
                continue
            self.pending = None
            if "error" in message:
                fail("server_error", "Language server rejected the request")
            if "result" not in message:
                fail("protocol_error", "Response has no result")
            return message["result"]

    def close(self):
        # Cancellation is best effort and must not extend the operation deadline.
        if self.pending is not None:
            try:
                self.notify("$/cancelRequest", {"id": self.pending})
            except Failure:
                pass
        self.stop.set()
        try:
            self.writes.put_nowait(None)
        except queue.Full:
            pass
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
            try:
                self.proc.wait(timeout=0.15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=0.5)
        except ProcessLookupError:
            self.proc.wait(timeout=0.5)
        self.threads[2].join(timeout=0.2)
        for thread in self.threads[:2]:
            thread.join(timeout=0.05)
        if not self.threads[2].is_alive():
            try:
                self.proc.stdin.close()
            except (OSError, ValueError):
                pass
        # Closing a buffered pipe held by a reader can deadlock if an inherited
        # descendant still holds it; the runner will kill that process group.
        if not any(thread.is_alive() for thread in self.threads[:2]):
            for stream in (self.proc.stdout, self.proc.stderr):
                try:
                    stream.close()
                except OSError:
                    pass


def run(request):
    operation = request.get("operation") if isinstance(request, dict) else None
    reply = {"version": 1, "operation": operation, "result": None, "complete": False}
    client = None
    try:
        command, root, path, text, timeout = validate(request)
        client = Client(command, root, time.monotonic() + timeout / 1000.0)
        client.uri = path.as_uri()
        client.request(1, "initialize", {
            "processId": os.getpid(), "rootUri": root.as_uri(),
            "workspaceFolders": [{"uri": root.as_uri(), "name": root.name}],
            "capabilities": {"general": {"positionEncodings": ["utf-16"]},
                             "textDocument": {"diagnostic": {"dynamicRegistration": False}}},
        })
        initialized = client.response(1)
        if not isinstance(initialized, dict) or not isinstance(initialized.get("capabilities"), dict):
            fail("protocol_error", "Invalid initialize result")
        capabilities = initialized["capabilities"]
        if capabilities.get("positionEncoding", "utf-16") != "utf-16":
            fail("unsupported_encoding", "Server did not select UTF-16 positions")
        client.notify("initialized", {})
        client.notify("textDocument/didOpen", {"textDocument": {
            "uri": client.uri, "languageId": request["language_id"], "version": 1, "text": text,
        }})
        params = {"textDocument": {"uri": client.uri}}
        if operation in ("hover", "definition", "references"):
            params["position"] = {"line": request["line"], "character": request["character"]}
        if operation == "references":
            params["context"] = {"includeDeclaration": True}
        if operation != "diagnostics":
            client.request(2, OPERATIONS[operation], params)
            reply["result"] = client.response(2)
        elif capabilities.get("diagnosticProvider") is not None and capabilities.get("diagnosticProvider") is not False:
            client.request(2, OPERATIONS[operation], params)
            report = client.response(2)
            if not isinstance(report, dict) or report.get("kind") != "full" or not isinstance(report.get("items"), list):
                fail("not_ready", "No full diagnostic report received")
            reply["result"] = report["items"]
            client.diagnostics = report["items"]
        else:
            while client.diagnostics is None:
                client.event()
            reply["result"] = client.diagnostics
        reply["complete"] = True
    except Failure as error:
        reply["error"] = {"code": error.code, "message": str(error)}
    except (OSError, ValueError, TypeError, OverflowError, RecursionError):
        reply["error"] = {"code": "transport_error", "message": "Unable to run language server"}
    finally:
        if client is not None:
            if client.diagnostics is not None:
                reply["diagnostics"] = client.diagnostics
            client.close()
    if client is not None:
        try:
            removed = [0]
            for key in ("result", "diagnostics"):
                if key in reply:
                    filtered = filter_locations(reply[key], root, removed)
                    reply[key] = None if filtered is _EXTERNAL else filtered
            if removed[0]:
                reply["filtered_external_locations"] = removed[0]
        except Failure as error:
            reply.update(result=None, complete=False,
                         error={"code": error.code, "message": str(error)})
            reply.pop("diagnostics", None)
    return reply


def main():
    try:
        if len(sys.argv) != 2 or len(sys.argv[1]) > 65536:
            fail("invalid_request", "Expected one bounded JSON request argument")
        request = strict_json(sys.argv[1])
        reply = run(request)
    except Failure as error:
        reply = {"version": 1, "operation": None, "result": None, "complete": False,
                 "error": {"code": error.code, "message": str(error)}}
    output = json.dumps(reply, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
    if len(output) > MAX_STDOUT:
        output = json.dumps({"version": 1, "operation": reply["operation"], "result": None,
                             "complete": False, "error": {"code": "limit_exceeded",
                             "message": "LSP reply limit exceeded"}})
    print(output)


if __name__ == "__main__":
    main()
