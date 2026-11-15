#!/usr/bin/env python3
"""Synthetic stdio LSP tests; python3 scripts/test_lsp_client.py -v."""
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "src" / "lsp_client.py"
SPEC = importlib.util.spec_from_file_location("lsp_client", SOURCE)
lsp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lsp)
EMBEDDED = SOURCE.read_text(encoding="utf-8")

# This server deliberately uses its own framing instead of importing the client.
SERVER = r'''
import json, os, signal, subprocess, sys, time
mode, pidfile = sys.argv[1:]
open(pidfile, 'w').write(str(os.getpid()))
def read():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if line == b'\r\n': break
        if not line: sys.exit(0)
        k, v = line.split(b':', 1)
        headers[k.lower()] = v.strip()
    return json.loads(sys.stdin.buffer.read(int(headers[b'content-length'])))
def send(message):
    raw = json.dumps(dict(jsonrpc='2.0', **message)).encode()
    sys.stdout.buffer.write(b'Content-Length: ' + str(len(raw)).encode() + b'\r\n\r\n' + raw)
    sys.stdout.buffer.flush()
def response(message, result): send(dict(id=message['id'], result=result))
if mode == 'ignore_term': signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode in ('descendant', 'descendant_success'):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
    open(pidfile + '.child', 'w').write(str(child.pid))
if mode == 'bad_frame':
    sys.stdout.buffer.write(b'Content-Length: no\r\n\r\n')
    sys.stdout.buffer.flush()
    time.sleep(60)
if mode == 'stderr':
    sys.stderr.buffer.write(b'x' * (300 * 1024)); sys.stderr.buffer.flush()
    time.sleep(60)
initialize = read()
assert initialize['method'] == 'initialize'
assert initialize['params']['capabilities']['general']['positionEncodings'] == ['utf-16']
assert initialize['params']['rootUri'].startswith('file:')
assert len(initialize['params']['workspaceFolders']) == 1
if mode == 'interleaved':
    send(dict(method='window/logMessage', params=dict(type=3, message='synthetic')))
    for req_id, method, params in [
        (41, 'workspace/configuration', dict(items=[{}, {}])),
        (42, 'workspace/applyEdit', dict(edit={})),
        (43, 'window/workDoneProgress/create', dict(token='synthetic')),
        (44, 'custom/unknown', {}),
        (45, 'workspace/workspaceFolders', {}),
    ]:
        send(dict(id=req_id, method=method, params=params))
        answer = read()
        assert answer['id'] == req_id
        if req_id == 41: assert answer['result'] == [None, None]
        elif req_id in (42, 44): assert answer['error']['code'] == -32601
        else: assert answer['result'] is None
caps = {'positionEncoding': 'utf-8'} if mode == 'wrong_encoding' else {}
if mode in ('pull', 'unchanged'): caps['diagnosticProvider'] = {}
response(initialize, dict(capabilities=caps))
if mode == 'no_read': time.sleep(60)
assert read()['method'] == 'initialized'
opened = read()
assert opened['method'] == 'textDocument/didOpen'
document = opened['params']['textDocument']
assert document['version'] == 1
uri = document['uri']
if mode == 'text': assert document['text'] == '/* 😀 */ int value = 7;\n'
if mode == 'push':
    send(dict(method='textDocument/publishDiagnostics', params=dict(uri=uri + '.other', diagnostics=[])))
    send(dict(method='textDocument/publishDiagnostics', params=dict(uri=uri, version=0, diagnostics=[])))
    send(dict(method='textDocument/publishDiagnostics', params=dict(uri=uri, version=1, diagnostics=[dict(message='synthetic diagnostic')])))
if mode == 'clean':
    send(dict(method='textDocument/publishDiagnostics', params=dict(uri=uri, diagnostics=[])))
if mode == 'stale':
    send(dict(method='textDocument/publishDiagnostics', params=dict(uri=uri, version=0, diagnostics=[])))
if mode == 'none' or mode == 'stale' or mode == 'descendant': time.sleep(60)
if mode == 'flood':
    for _ in range(270): send(dict(method='window/logMessage', params={}))
if mode == 'exit': sys.exit(0)
operation = read()
if mode == 'error': send(dict(id=operation['id'], error=dict(code=-32800, message='cancelled')))
elif mode == 'pull': response(operation, dict(kind='full', items=[]))
elif mode == 'unchanged': response(operation, dict(kind='unchanged', resultId='synthetic'))
elif mode == 'locations':
    response(operation, [dict(uri=uri, range={}), dict(uri='file:///outside-synthetic.c', range={}),
                        dict(targetUri='file:///outside-synthetic.c', targetRange={}),
                        dict(uri='https://example.invalid/fixture.c', range={})])
elif mode == 'symbols':
    response(operation, [dict(name='local', location=dict(uri=uri, range={})),
                        dict(name='external', location=dict(uri='file:///outside-synthetic.c', range={}))])
elif operation['method'] == 'textDocument/references':
    assert operation['params']['context']['includeDeclaration'] is True
    response(operation, [])
elif operation['method'] == 'textDocument/documentSymbol': response(operation, [])
else:
    if mode == 'text': assert operation['params']['position'] == dict(line=0, character=13)
    response(operation, dict(contents='synthetic hover'))
time.sleep(60)
'''


class FramingTests(unittest.TestCase):
    def test_valid_utf8_with_extra_header(self):
        message = {"jsonrpc": "2.0", "id": 1, "result": "λ"}
        raw = json.dumps(message, ensure_ascii=False).encode("utf-8")
        frame = b"Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: "
        frame += str(len(raw)).encode() + b"\r\n\r\n" + raw
        self.assertEqual(lsp.read_frame(io.BytesIO(frame)), message)
        self.assertIsNone(lsp.read_frame(io.BytesIO(b"")))

    def test_invalid_framing_is_rejected(self):
        frames = [
            b"Content-Length: x\r\n\r\n", b"Content-Length: -1\r\n\r\n",
            b"Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            b"BadHeader\r\n\r\n", b"Other: 2\r\n\r\n{}",
            b"Content-Length: 99999999\r\n\r\n", b"Content-Length: 0\r\n\r\n",
            b"Content-Length: 2\r\n", b"Content-Length: 10\r\n\r\n{}",
            b"Content-Length: 2\r\n\r\n[]", b"Content-Length: 2\r\n\r\n{}",
            b"Content-Length: 1\r\n\r\n\xff", b"x" * (lsp.MAX_HEADER + 1),
        ]
        for frame in frames:
            with self.subTest(prefix=frame[:40]), self.assertRaises(lsp.Failure):
                lsp.read_frame(io.BytesIO(frame))

    def test_total_stdout_budget(self):
        frame = lsp.encode_frame({"jsonrpc": "2.0", "result": None, "id": 1})
        with self.assertRaises(lsp.Failure) as error:
            lsp.read_frame(io.BytesIO(frame), [lsp.MAX_STDOUT])
        self.assertEqual(error.exception.code, "limit_exceeded")

    def test_nonfinite_json_is_rejected(self):
        with self.assertRaises(lsp.Failure):
            lsp.strict_json('{"jsonrpc":"2.0","result":NaN}')


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lsp-synthetic-")
        self.root = Path(self.temp.name)
        self.source = self.root / "fixture.c"
        self.source.write_text("int value = 7;\n", encoding="utf-8")
        self.server = self.root / "server.py"
        self.server.write_text(SERVER, encoding="utf-8")
        self.pidfile = self.root / "server.pid"

    def tearDown(self):
        self.temp.cleanup()

    def request(self, mode="interleaved", operation="hover", **changes):
        request = dict(command=[sys.executable, "-u", str(self.server), mode, str(self.pidfile)],
                       root=str(self.root), path=str(self.source), language_id="c",
                       operation=operation, line=0, character=4, timeout_ms=1500)
        request.update(changes)
        return request

    def invoke(self, request):
        completed = subprocess.run([sys.executable, "-c", EMBEDDED, json.dumps(request)],
                                   capture_output=True, timeout=15)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
        self.assertEqual(completed.stderr, b"")
        reply = json.loads(completed.stdout)
        self.assertEqual(reply["version"], 1)
        self.assertEqual(reply["operation"], request["operation"])
        return reply

    def assert_server_gone(self):
        pid = int(self.pidfile.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)


class ClientTests(Fixture):
    def test_real_requests_and_safe_interleaving(self):
        reply = self.invoke(self.request())
        self.assertTrue(reply["complete"], reply)
        self.assertEqual(reply["result"]["contents"], "synthetic hover")
        self.assert_server_gone()

    def test_push_diagnostics_filters_other_documents_and_versions(self):
        reply = self.invoke(self.request("push", "diagnostics"))
        self.assertTrue(reply["complete"], reply)
        self.assertEqual(reply["result"], [{"message": "synthetic diagnostic"}])
        self.assertEqual(reply["diagnostics"], reply["result"])

    def test_explicit_clean_push_and_pull(self):
        for mode in ("clean", "pull"):
            with self.subTest(mode=mode):
                reply = self.invoke(self.request(mode, "diagnostics"))
                self.assertTrue(reply["complete"], reply)
                self.assertEqual(reply["result"], [])
                self.assertEqual(reply["diagnostics"], [])

    def test_absent_or_stale_diagnostics_are_not_clean(self):
        for mode in ("none", "stale"):
            with self.subTest(mode=mode):
                reply = self.invoke(self.request(mode, "diagnostics", timeout_ms=250))
                self.assertFalse(reply["complete"])
                self.assertIsNone(reply["result"])
                self.assertNotIn("diagnostics", reply)
                self.assertEqual(reply["error"]["code"], "timeout")
                self.assert_server_gone()

    def test_unchanged_pull_without_baseline_is_not_clean(self):
        reply = self.invoke(self.request("unchanged", "diagnostics"))
        self.assertFalse(reply["complete"])
        self.assertEqual(reply["error"]["code"], "not_ready")
        self.assertNotIn("diagnostics", reply)

    def test_protocol_error_event_limit_stderr_limit_and_server_errors(self):
        for mode, expected in [("bad_frame", "protocol_error"), ("flood", "limit_exceeded"),
                               ("stderr", "limit_exceeded"), ("error", "server_error"),
                               ("exit", "server_exited"), ("wrong_encoding", "unsupported_encoding")]:
            with self.subTest(mode=mode):
                reply = self.invoke(self.request(mode))
                self.assertFalse(reply["complete"], reply)
                self.assertEqual(reply["error"]["code"], expected, reply)
                self.assert_server_gone()

    def test_references_and_symbols(self):
        for operation in ("references", "document_symbols"):
            with self.subTest(operation=operation):
                reply = self.invoke(self.request(operation=operation))
                self.assertTrue(reply["complete"], reply)
                self.assertEqual(reply["result"], [])

    def test_external_locations_links_and_symbols_are_filtered(self):
        for mode, operation in (("locations", "definition"), ("locations", "references"),
                                ("symbols", "document_symbols")):
            with self.subTest(operation=operation):
                reply = self.invoke(self.request(mode, operation))
                self.assertTrue(reply["complete"], reply)
                self.assertEqual(len(reply["result"]), 1)
                self.assertGreater(reply["filtered_external_locations"], 0)
                self.assertNotIn("outside-synthetic", json.dumps(reply))
                self.assertNotIn("example.invalid", json.dumps(reply))

    def test_location_symlink_escape_and_nesting_limit(self):
        with tempfile.TemporaryDirectory(prefix="lsp-synthetic-outside-") as other:
            link = self.root / "escape.c"
            try:
                link.symlink_to(Path(other) / "target.c")
            except (OSError, NotImplementedError):
                self.skipTest("symlinks unavailable")
            removed = [0]
            result = lsp.filter_locations([{"uri": link.as_uri()}], self.root.resolve(), removed)
            self.assertEqual(result, [])
            self.assertEqual(removed, [1])
        removed = [0]
        malformed = [{"uri": None}, {"uri": 7}, {"uri": {}}, {"uri": "file:///bad%FF"}]
        self.assertEqual(lsp.filter_locations(malformed, self.root.resolve(), removed), [])
        self.assertEqual(removed, [4])
        value = None
        for _ in range(66):
            value = [value]
        with self.assertRaises(lsp.Failure):
            lsp.filter_locations(value, self.root.resolve(), [0])

    def test_cleanup_kills_server_ignoring_terminate(self):
        reply = self.invoke(self.request("ignore_term"))
        self.assertTrue(reply["complete"], reply)
        self.assert_server_gone()

    def test_actual_text_and_utf16_position(self):
        self.source.write_text("/* 😀 */ int value = 7;\n", encoding="utf-8")
        reply = self.invoke(self.request("text", character=13))
        self.assertTrue(reply["complete"], reply)
        invalid = self.invoke(self.request("text", character=4))
        self.assertEqual(invalid["error"]["code"], "invalid_request")

    def test_validation_precedes_launch(self):
        outside = self.root.parent / "not-in-root.c"
        for change in [dict(timeout_ms=10001), dict(timeout_ms=True), dict(line=-1),
                       dict(character=1000), dict(path=str(outside)), dict(path="fixture.c"),
                       dict(operation="execute_command"), dict(command="python3"),
                       dict(command=[]), dict(language_id="")]:
            with self.subTest(change=change):
                reply = self.invoke(self.request(**change))
                self.assertFalse(reply["complete"])
                self.assertEqual(reply["error"]["code"], "invalid_request", reply)
                self.assertFalse(self.pidfile.exists())

    def test_source_limit_and_utf8(self):
        self.source.write_bytes(b"a" * (lsp.MAX_SOURCE + 1))
        self.assertEqual(self.invoke(self.request())["error"]["code"], "limit_exceeded")
        self.source.write_bytes(b"\xff")
        self.assertEqual(self.invoke(self.request())["error"]["code"], "invalid_request")
        self.assertFalse(self.pidfile.exists())

    def test_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="lsp-synthetic-outside-") as other:
            target = Path(other) / "outside.c"
            target.write_text("int outside;\n")
            link = self.root / "escape.c"
            try:
                link.symlink_to(target)
            except (OSError, NotImplementedError):
                self.skipTest("symlinks unavailable")
            reply = self.invoke(self.request(path=str(link)))
            self.assertEqual(reply["error"]["code"], "invalid_request")

    def test_blocked_stdin_has_real_deadline_and_child_cleanup(self):
        self.source.write_text("x" * (lsp.MAX_SOURCE - 1))
        started = time.monotonic()
        reply = self.invoke(self.request("no_read", timeout_ms=200))
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(reply["error"]["code"], "timeout")
        self.assert_server_gone()

    @unittest.skipUnless(os.name == "posix", "POSIX process-group ownership")
    def test_outer_runner_owns_descendants_on_normal_exit_and_timeout(self):
        # Match process_runner's normal/cancel cleanup: helper must not detach.
        for mode, operation in (("descendant", "diagnostics"), ("descendant_success", "hover")):
            with self.subTest(mode=mode):
                process = subprocess.Popen([sys.executable, "-c", EMBEDDED,
                                            json.dumps(self.request(mode, operation, timeout_ms=300))],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                child_pid = None
                try:
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, stderr)
                    reply = json.loads(stdout)
                    if mode == "descendant":
                        self.assertEqual(reply["error"]["code"], "timeout")
                    else:
                        self.assertTrue(reply["complete"], reply)
                    child_pid = int(Path(str(self.pidfile) + ".child").read_text())
                    self.assertEqual(os.getpgid(child_pid), process.pid)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=2)
                # Zombies have terminated but await init's OS-level reaping.
                for _ in range(20):
                    observed = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(child_pid)],
                                              capture_output=True, timeout=1).stdout.strip()
                    if not observed or observed.startswith(b"Z"):
                        break
                    time.sleep(0.05)
                self.assertTrue(not observed or observed.startswith(b"Z"), observed)


@unittest.skipUnless(Path("/usr/bin/clangd").is_file(), "installed clangd unavailable")
class InstalledClangdTests(Fixture):
    def test_installed_clangd_diagnostics_hover_definition(self):
        command = ["/usr/bin/clangd", "--background-index=false", "--clang-tidy=false", "--log=error"]
        for suffix, language in (("c", "c"), ("cpp", "cpp")):
            self.source = self.root / ("fixture." + suffix)
            self.source.write_text("int square(int x) { return x * x; }\n"
                                   "int main(void) { return square(3); }\n"
                                   "int broken = missing_symbol;\n", encoding="utf-8")
            replies = {}
            for operation in ("diagnostics", "hover", "definition"):
                with self.subTest(language=language, operation=operation):
                    reply = self.invoke(self.request(operation=operation, command=command,
                                                     language_id=language, line=1,
                                                     character=25, timeout_ms=10000))
                    self.assertTrue(reply["complete"], reply)
                    replies[operation] = reply
            diagnostics = replies["diagnostics"]["result"]
            self.assertTrue(any(item.get("severity") == 1 and "missing_symbol" in item.get("message", "")
                                for item in diagnostics), diagnostics)
            self.assertIn("square", json.dumps(replies["hover"]["result"]))
            definitions = replies["definition"]["result"]
            self.assertTrue(definitions, definitions)
            location = definitions[0] if isinstance(definitions, list) else definitions
            target = location.get("targetUri", location.get("uri"))
            self.assertEqual(target, self.source.resolve().as_uri())
            position = location.get("targetSelectionRange", location.get("range"))["start"]
            self.assertEqual(position["line"], 0)
            self.assertEqual(position["character"], 4)


if __name__ == "__main__":
    unittest.main()
