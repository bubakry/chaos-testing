#!/usr/bin/env python3

import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = os.getenv('HOST', '0.0.0.0')
PORT = int(os.getenv('PORT', '5001'))
LOG_FILE = os.getenv('LOG_FILE', 'chaos-testing-alerts.log')


class Handler(BaseHTTPRequestHandler):
    def _write(self, status: int, body: str):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body.encode('utf-8'))

    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        payload = self.rfile.read(content_length).decode('utf-8')

        timestamp = datetime.now(timezone.utc).isoformat()
        try:
            parsed = json.loads(payload) if payload else {}
        except json.JSONDecodeError:
            parsed = {'raw': payload}

        event = {
            'timestamp': timestamp,
            'path': self.path,
            'alerts': parsed
        }

        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(json.dumps(event) + '\n')

        print(json.dumps(event, indent=2), flush=True)
        self._write(200, json.dumps({'received': True}))

    def log_message(self, fmt, *args):
        return


if __name__ == '__main__':
    server = HTTPServer((HOST, PORT), Handler)
    print(f'Mock on-call webhook listening on http://{HOST}:{PORT}', flush=True)
    print(f'Writing alert payloads to {LOG_FILE}', flush=True)
    server.serve_forever()
