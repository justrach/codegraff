#!/usr/bin/env python3
"""Offline GUI fixture: title generation cannot consume agent turn replies."""
if __name__ == '__main__':
    print('Starting scripted model fixture', flush=True)

import argparse
import json
from pathlib import Path
import threading
from mock_model import ScriptedModel


class FrontendModel(ScriptedModel):
    def __init__(self, script, requests_path, title_failures=0):
        super().__init__(script)
        self.requests_path = Path(requests_path)
        self.title_failures = title_failures

    def next_reply(self, body):
        if not body.get('tools'):
            if self.title_failures:
                self.title_failures -= 1
                return {'http_status': 400, 'error': 'Title fixture rejected request'}
            return {'text': 'Retained work'}
        reply = super().next_reply(body)
        self.requests_path.write_text(json.dumps(self.requests))
        return reply


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--script', required=True)
    parser.add_argument('--requests', required=True)
    parser.add_argument('--title-failures', type=int, default=0)
    args = parser.parse_args()
    model = FrontendModel(json.loads(Path(args.script).read_text()), args.requests, args.title_failures)
    print('Binding scripted model fixture', flush=True)
    model.start(1234)
    print('scripted model on 127.0.0.1:1234', flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        model.stop()
