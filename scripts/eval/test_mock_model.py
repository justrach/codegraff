#!/usr/bin/env python3
"""The offline model must start and answer without DNS services."""
import http.client
import json
import unittest
from unittest.mock import patch

from mock_model import ScriptedModel


class LoopbackFixtureTests(unittest.TestCase):
    def test_start_and_request_without_hostname_resolution(self):
        model = ScriptedModel([{'text': 'fixture ready'}])
        with patch('socket.getfqdn', side_effect=AssertionError('DNS unavailable')):
            port = model.start(0)
            self.addCleanup(model.stop)
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
            self.addCleanup(connection.close)
            connection.request('POST', '/v1/chat/completions',
                               json.dumps({'messages': [], 'stream': False}),
                               {'Content-Type': 'application/json'})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read())['choices'][0]['message']['content'],
                             'fixture ready')
            self.assertEqual(len(model.requests), 1)


if __name__ == '__main__':
    unittest.main()
