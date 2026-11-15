"""Bounded per-workspace warm stdio LSP session manager (POSIX)."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import signal
import socket
import stat
import subprocess
import sys
import time
import types

_EMPTY = object()


def load_client(src):
    mod = types.ModuleType("lsp_client")
    sys.modules["lsp_client"] = mod
    exec(compile(src, "<lsp_client.py>", "exec"), mod.__dict__)
    return mod


def make_warm_client(lsp):
    class WarmClient(lsp.Client):
        def __init__(self, command, root, deadline):
            super().__init__(command, root, deadline, new_session=True)
            self.doc_versions = {}
            self.doc_diags = {}

        def _process(self, value):
            self.count += 1
            if self.count > lsp.MAX_EVENTS:
                lsp.fail("limit_exceeded", "LSP event limit exceeded")
            if "method" not in value:
                return value
            method, params = value["method"], value.get("params", {})
            if "id" in value:
                self._server_request(value)
            elif method == "experimental/serverStatus" and isinstance(params, dict):
                if isinstance(params.get("quiescent"), bool):
                    self.quiescent = params["quiescent"]
            elif method == "textDocument/publishDiagnostics" and isinstance(params, dict):
                pub_uri = params.get("uri")
                uri = self.uri if (self.uri and lsp.same_uri(pub_uri, self.uri, self.doc_path)) else pub_uri
                expected = self.doc_versions.get(uri, 1)
                if params.get("version", expected) in (None, expected):
                    diagnostics = params.get("diagnostics")
                    if not isinstance(diagnostics, list):
                        lsp.fail("protocol_error", "Invalid diagnostics notification")
                    self.doc_diags[uri] = diagnostics
                    if uri == self.uri:
                        self.diagnostics = diagnostics
            return None

        def event(self, block=True):
            try:
                kind, value = self.events.get(timeout=self.remaining()) if block else self.events.get_nowait()
            except queue.Empty:
                if block:
                    lsp.fail("timeout", "Language server timed out; result is not ready")
                return _EMPTY
            if kind == "failure":
                raise value
            if value is None:
                lsp.fail("server_exited", "Language server exited before completing the operation")
            return self._process(value)

        def drain(self):
            while self.event(block=False) is not _EMPTY:
                pass

        def query_with_retry(self, state, method, params):
            while True:
                req_id = state["next_id"]
                state["next_id"] += 1
                self.request(req_id, method, params)
                while True:
                    message = self.event()
                    if message is None or message.get("id") != req_id:
                        continue
                    self.pending = None
                    if "error" not in message:
                        if "result" not in message:
                            lsp.fail("protocol_error", "Response has no result")
                        return message["result"]
                    err = message["error"]
                    code = err.get("code") if isinstance(err, dict) else None
                    if code in (-32801, -32802) and self.deadline - time.monotonic() > 0.3:
                        time.sleep(0.15)
                        self.drain()
                        break
                    lsp.fail("server_error", "Language server rejected the request")
    return WarmClient


def sock_paths(lsp, root, server_id, command):
    sock_dir = Path(f"/tmp/graff-lsp-{os.getuid()}")
    if sock_dir.is_symlink():
        lsp.fail("invalid_request", "Unsafe LSP socket directory")
    sock_dir.mkdir(mode=0o700, exist_ok=True)
    st = sock_dir.stat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        lsp.fail("invalid_request", "Unsafe LSP socket directory")
    os.chmod(sock_dir, 0o700)
    key = hashlib.sha256(json.dumps([str(root), server_id or "", command], sort_keys=True).encode("utf-8")).hexdigest()[:16]
    return sock_dir / f"{key}.sock", sock_dir / f"{key}.lock"


def close_client(client):
    if client is None:
        return
    pid = client.proc.pid
    try:
        client.close()
    finally:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def read_line(conn, limit):
    buf = bytearray()
    while len(buf) < limit:
        chunk = conn.recv(4096)
        if not chunk:
            break
        nl = chunk.find(b"\n")
        if nl >= 0:
            buf.extend(chunk[:nl])
            return bytes(buf)
        buf.extend(chunk)
    return bytes(buf)


def handle_query(lsp, WarmClient, state, cfg, root, req):
    op = req.get("operation") if isinstance(req, dict) else None
    reply = {"version": 1, "operation": op, "result": None, "complete": False, "warm_hit": False}
    fatal = False
    try:
        command, r_root, path, text, timeout = lsp.validate(req)
        if command != cfg["command"] or str(r_root) != str(root):
            lsp.fail("invalid_request", "LSP warm session configuration mismatch")
        deadline = time.monotonic() + timeout / 1000.0
        if state["client"] is not None:
            if state["client"].proc.poll() is not None:
                close_client(state["client"])
                state["client"] = None
            else:
                try:
                    state["client"].deadline = deadline
                    state["client"].count = 0
                    state["client"].read_budget[0] = 0
                    state["client"].drain()
                except lsp.Failure:
                    close_client(state["client"])
                    state["client"] = None
        if state["client"] is None:
            client = WarmClient(command, root, deadline)
            client.request(1, "initialize", {
                "processId": os.getpid(), "rootUri": root.as_uri(),
                "workspaceFolders": [{"uri": root.as_uri(), "name": root.name}],
                "capabilities": {"general": {"positionEncodings": ["utf-16"]},
                                 "textDocument": {"publishDiagnostics": {"relatedInformation": True},
                                                  "diagnostic": {"dynamicRegistration": False}},
                                 "experimental": {"serverStatusNotification": True}},
            })
            initialized = client.response(1)
            if not isinstance(initialized, dict) or not isinstance(initialized.get("capabilities"), dict):
                lsp.fail("protocol_error", "Invalid initialize result")
            caps = initialized["capabilities"]
            if caps.get("positionEncoding", "utf-16") != "utf-16":
                lsp.fail("unsupported_encoding", "Server did not select UTF-16 positions")
            client.notify("initialized", {})
            server_name = (initialized.get("serverInfo") or {}).get("name") if isinstance(initialized.get("serverInfo"), dict) else None
            state.update(client=client, caps=caps, next_id=2, docs={}, needs_quiescent=(server_name == "rust-analyzer"))
        else:
            reply["warm_hit"] = True
            client = state["client"]
            client.deadline = deadline
            client.count = 0
            client.read_budget[0] = 0
        uri = path.as_uri()
        client.uri = uri
        client.doc_path = path
        doc_hash = hashlib.sha256(text.encode("utf-8")).digest()
        entry = state["docs"].get(uri)
        if entry is None:
            state["docs"][uri] = {"version": 1, "hash": doc_hash}
            client.doc_versions[uri] = 1
            client.doc_diags.pop(uri, None)
            client.diagnostics = None
            client.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": req["language_id"], "version": 1, "text": text}})
        elif entry["hash"] != doc_hash:
            ver = entry["version"] + 1
            entry["version"], entry["hash"] = ver, doc_hash
            client.doc_versions[uri] = ver
            client.doc_diags.pop(uri, None)
            client.diagnostics = None
            client.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": ver}, "contentChanges": [{"text": text}]})
        else:
            client.diagnostics = client.doc_diags.get(uri)
        if state.get("needs_quiescent"):
            while client.quiescent is not True:
                client.event()
            state["needs_quiescent"] = False
        params = {"textDocument": {"uri": uri}}
        if op in ("hover", "definition", "references"):
            params["position"] = {"line": req["line"], "character": req["character"]}
        if op == "references":
            params["context"] = {"includeDeclaration": True}
        if op != "diagnostics":
            reply["result"] = client.query_with_retry(state, lsp.OPERATIONS[op], params)
        elif state["caps"].get("diagnosticProvider") not in (None, False):
            report = client.query_with_retry(state, lsp.OPERATIONS[op], params)
            if not isinstance(report, dict) or report.get("kind") != "full" or not isinstance(report.get("items"), list):
                lsp.fail("not_ready", "No full diagnostic report received")
            reply["result"] = report["items"]
            client.doc_diags[uri] = report["items"]
            client.diagnostics = report["items"]
        else:
            while client.doc_diags.get(uri) is None:
                client.event()
            reply["result"] = client.doc_diags[uri]
            client.diagnostics = client.doc_diags[uri]
        reply["complete"] = True
        if client.doc_diags.get(uri) is not None:
            reply["diagnostics"] = client.doc_diags[uri]
    except lsp.Failure as error:
        reply["error"] = {"code": error.code, "message": str(error)}
        fatal = error.code in ("timeout", "protocol_error", "transport_error", "server_exited", "limit_exceeded")
    except (OSError, ValueError, TypeError, OverflowError, RecursionError):
        reply["error"] = {"code": "transport_error", "message": "Unable to run language server"}
        fatal = True
    if state["client"] is not None and "error" not in reply:
        try:
            removed = [0]
            for key in ("result", "diagnostics"):
                if key in reply:
                    filtered = lsp.filter_locations(reply[key], root, removed)
                    reply[key] = None if filtered is lsp._EXTERNAL else filtered
            if removed[0]:
                reply["filtered_external_locations"] = removed[0]
        except lsp.Failure as error:
            reply.update(result=None, complete=False, error={"code": error.code, "message": str(error)})
            reply.pop("diagnostics", None)
    return reply, fatal


def run_daemon(lsp, cfg_json):
    cfg = json.loads(cfg_json)
    root = Path(cfg["root"])
    sock_path = Path(cfg["sock_path"])
    ttl_s = cfg["warm_ttl_ms"] / 1000.0
    WarmClient = make_warm_client(lsp)
    state = {"client": None, "caps": {}, "next_id": 2, "docs": {}}
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock_path.unlink(missing_ok=True)
    srv.bind(str(sock_path))
    os.chmod(sock_path, 0o600)
    srv.listen(8)
    srv.settimeout(0.1)
    last_active = time.monotonic()
    try:
        while True:
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                if time.monotonic() - last_active >= ttl_s:
                    break
                continue
            last_active = time.monotonic()
            stop_daemon = False
            with conn:
                conn.settimeout(5.0)
                raw = read_line(conn, 65536)
                req = lsp.strict_json(raw.decode("utf-8")) if raw else {}
                if isinstance(req, dict) and req.get("op") == "__shutdown":
                    reply, stop_daemon = {"version": 1, "stopped": True}, True
                else:
                    reply, stop_daemon = handle_query(lsp, WarmClient, state, cfg, root, req)
                payload = json.dumps(reply, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
                if len(payload) > min(60000, lsp.MAX_STDOUT):
                    payload = json.dumps({"version": 1, "operation": reply.get("operation"), "result": None, "complete": False, "error": {"code": "limit_exceeded", "message": "LSP reply limit exceeded"}})
                conn.sendall(payload.encode("utf-8") + b"\n")
            last_active = time.monotonic()
            if stop_daemon:
                break
    finally:
        close_client(state["client"])
        srv.close()
        sock_path.unlink(missing_ok=True)


def query_sock(sock_path, payload_bytes, timeout_s):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout_s)
        s.connect(str(sock_path))
        s.sendall(payload_bytes + b"\n")
        out = bytearray()
        while len(out) < 65536:
            chunk = s.recv(8192)
            if not chunk:
                break
            nl = chunk.find(b"\n")
            if nl >= 0:
                out.extend(chunk[:nl])
                return bytes(out).decode("utf-8")
            out.extend(chunk)
        return bytes(out).decode("utf-8")


def run_client(lsp, warm_src, client_src, req_json):
    req = lsp.strict_json(req_json)
    if not isinstance(req, dict):
        lsp.fail("invalid_request", "Expected request object")
    if req.get("operation") == "__shutdown_warm":
        root = Path(req["root"]).resolve(strict=True)
        sock_path, _ = sock_paths(lsp, root, req.get("server_id", ""), req["command"])
        try:
            return query_sock(sock_path, json.dumps({"op": "__shutdown"}).encode("utf-8"), 2.0)
        except OSError:
            return json.dumps({"version": 1, "operation": "__shutdown_warm", "result": {"stopped": False}, "complete": True})
    command, root, _, _, timeout = lsp.validate(req)
    warm_ttl = req.get("warm_ttl_ms", 0)
    if type(warm_ttl) is not int or not 100 <= warm_ttl <= 300000:
        lsp.fail("invalid_request", "warm_ttl_ms must be between 100 and 300000")
    sock_path, lock_path = sock_paths(lsp, root, req.get("server_id", ""), command)
    payload = json.dumps(req, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    wait_s = timeout / 1000.0 + 1.5
    try:
        return query_sock(sock_path, payload, wait_s)
    except OSError:
        pass
    with lock_path.open("a+") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        try:
            return query_sock(sock_path, payload, wait_s)
        except OSError:
            sock_path.unlink(missing_ok=True)
            cfg = {"command": command, "root": str(root), "server_id": req.get("server_id", ""), "warm_ttl_ms": warm_ttl, "sock_path": str(sock_path)}
            subprocess.Popen([sys.executable, "-c", warm_src, warm_src, client_src, "--daemon", json.dumps(cfg)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True, close_fds=True)
            deadline = time.monotonic() + min(timeout / 1000.0, 5.0)
            while time.monotonic() < deadline:
                if sock_path.exists():
                    try:
                        return query_sock(sock_path, payload, wait_s)
                    except OSError:
                        pass
                time.sleep(0.02)
    lsp.fail("transport_error", "Warm LSP daemon did not become ready")


def main():
    op = None
    try:
        if len(sys.argv) < 4:
            raise ValueError("Expected warm arguments")
        lsp = load_client(sys.argv[2])
        if sys.argv[3] == "--daemon":
            run_daemon(lsp, sys.argv[4])
            return
        try:
            op = json.loads(sys.argv[3]).get("operation")
        except Exception:
            op = None
        print(run_client(lsp, sys.argv[1], sys.argv[2], sys.argv[3]))
    except Exception as error:
        code = getattr(error, "code", "transport_error")
        msg = str(error) if hasattr(error, "code") else "Unable to run warm language server"
        print(json.dumps({"version": 1, "operation": op, "result": None, "complete": False, "error": {"code": code, "message": msg}}))


if __name__ == "__main__":
    main()
