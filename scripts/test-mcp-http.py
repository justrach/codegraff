#!/usr/bin/env python3
"""Offline HTTP MCP regression: isolated HOME, no service manager or user configs."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import sys
sys.path.insert(0, str(Path(__file__).parent / 'eval'))
from mock_model import ScriptedModel


def main():
    exe = str(Path('zig-out/bin/graff').resolve())
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = 'a' * 64
    with tempfile.TemporaryDirectory() as home:
        env = {'HOME': home, 'PATH': os.environ['PATH'], 'GRAFF_MCP_TOKEN': token,
               'GRAFF_NO_PLUGINS': '1', 'GRAFF_NO_TELEMETRY': '1', 'GRAFF_FLEET': 'off',
               'GRAFF_NO_SMOLIFY': '1', 'LMSTUDIO_API_KEY': 'local'}
        process = subprocess.Popen([exe, 'mcp', 'serve', '--http', '--port', str(port), '--model', 'lmstudio'],
                                   env=env, cwd=home, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def post(method='POST', body=None, sid=None, extra=None):
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
            headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                       'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-06-18'}
            if sid:
                headers['Mcp-Session-Id'] = sid
            headers.update(extra or {})
            connection.request(method, '/mcp', json.dumps(body).encode() if body is not None else b'', headers)
            response = connection.getresponse()
            data = response.read()
            result = (response.status, json.loads(data) if data else None, response.getheader('Mcp-Session-Id'))
            connection.close()
            return result
        initialize = {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}}}
        try:
            for _ in range(100):
                try:
                    status, result, sid = post(body=initialize)
                    break
                except ConnectionRefusedError:
                    if process.poll() is not None:
                        raise AssertionError(process.stderr.read().decode())
                    time.sleep(.05)
            else:
                raise AssertionError('HTTP server did not start')
            assert status == 200 and len(sid) == 32
            assert result['result']['serverInfo']['name'] == 'codegraff'
            assert post(body=initialize, extra={'Authorization': 'wrong'})[0] == 401
            assert post(body=initialize, extra={'Origin': 'https://unrelated.example'})[0] == 403
            assert post(body=initialize, extra={'Host': 'unrelated.example'})[0] == 403
            assert post('GET')[0] == 405
            assert post(body=initialize, extra={'MCP-Protocol-Version': 'invalid'})[0] == 400
            assert post(body={'jsonrpc': '2.0', 'method': 'notifications/initialized'}, sid=sid)[:2] == (202, None)
            status, listing, _ = post(body={'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}, sid=sid)
            assert status == 200 and '_meta' not in listing['result']['tools'][0]
            initialize['params']['capabilities'] = {'extensions': {'io.modelcontextprotocol/ui': {'mimeTypes': ['text/html;profile=mcp-app']}}}
            _, _, second = post(body=initialize)
            assert second != sid
            post(body={'jsonrpc': '2.0', 'method': 'notifications/initialized'}, sid=second)
            _, listing, _ = post(body={'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}, sid=second)
            assert listing['result']['tools'][0]['_meta']['ui']['resourceUri'] == 'ui://codegraff/task-result'
            _, resource, _ = post(body={'jsonrpc': '2.0', 'id': 3, 'method': 'resources/read', 'params': {'uri': 'ui://codegraff/task-result'}}, sid=second)
            assert 'class="workspace"' in resource['result']['contents'][0]['text']
            model = ScriptedModel([{'text': 'HTTP_TASK_OK'}] * 8, exhausted_text='HTTP_TASK_OK')
            model.start(1234)
            try:
                status, result, _ = post(body={'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'run_task', 'arguments': {'prompt': 'Reply HTTP_TASK_OK. A greeting; no tools needed.', 'timeout_seconds': 20}}}, sid=sid)
                assert status == 200 and not result['result']['isError'], result
                assert 'HTTP_TASK_OK' in result['result']['structuredContent']['text']
            finally:
                model.stop()
            assert post('DELETE', sid=sid)[0] == 204
            assert post(body={'jsonrpc': '2.0', 'id': 5, 'method': 'ping'}, sid=sid)[0] == 404
            assert post(body={'jsonrpc': '2.0', 'id': 6, 'method': 'ping'}, sid=second)[0] == 200
        finally:
            process.terminate()
            process.wait(timeout=10)
    print('HTTP MCP: authentication, origins, methods, isolated sessions, app resource, real task and deletion passed')

if __name__ == '__main__':
    main()
